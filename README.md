# What is Apollo?

Apollo is a self-healing system written on top of
[consul](http://www.consul.io).

It originally started as a Flickr (part of Yahoo) project for helping in the
automation of fixing common issues that Ops people find and to give them more
time to focus on more important things.

If you been in the Ops world (call it devops, SRE, production engineer, service
engineer, etc) we are sure that you have seen the following:

* One or a few of your hosts start having hardware issues and then start causing
HTTP 500s to your users.
* Your hosts connect to other backend services and there is always the small
chance that some of those services will become unreliable and if your
application supports it then you might be able to disable connecting to that
service or failover to another one.
* You use APC and there are a few times when the APC will need to be reset (or
clean).

All those (and a lot more!) could obviously be automated and having a super
reliable system that has auto-degradation for backends that fail and an amazing
load balancing that quickly stops sending traffic to those bad hosts... but as
said, if you been doing Ops, sometimes you need to fight the battles with what
you have and there might be other components that are taking more priority to
create than to fix (or re-architect) the bad ones.

And you might have an entire operations center team looking at alerts and going to
fix them (add to this hundreds of thousands of servers) but we also know that
humans are not perfect and also not really that fast... so for that we created
Apollo, a system that would take care of taking those bad hosts out of rotation,
fixing them and putting them back in rotation after they get fixed, the result?
A lower TTR (Time-To-Respond) in your incidents!

But now you might be thinking: well, I could just write a cronjob that looks at
things, if they are bad then it takes them out of rotation and fix them and be done
with it.... well, technically you can do that but as mentioned, when you have
hundreds of thousands of servers, imagine that you get a sudden spike of
traffic or a spike of errors, how would your script know how to backoff if it
finds too many errors across the other hosts? You do not want all your hosts to
be taken out of rotation at once and you also do not want to to end up in a case
where you have cronjobs trying to fix things at 00:00 (yes, we all been there).

How does it works?

We will explain how it works by describing a close to real-life example and then
we will be going down with the details.

Imagine that you run a web site, it has a bunch of hosts serving HTTP traffic
(we will call them www hosts), those hosts later connect to other backend
services such as memcache, a storage component and another component for serving
those bytes that the storage component stored. You have two datacenters and
your have 100 hosts (call it VMs, bare-metals, etc) at www-west and www-east.

The problem you have: there are times when those wwws hosts will show problems
and the load-balancer would still keep them in rotation because the health-check
is still functional. Some of those problems can be:

* Load (uptime) issues.
* Some HTTP 500s, can be specific to a given host or across (bad deploys)
* Corrupted APC
* You have two storage systems, storage_one and storage_two. You can write to
any of them but not to both (at the same time). The only reason of why you will
switch to storage_two is because storage_one is down.

To add more complexity, you can take hosts out of rotation but no more than 30%
of the total of hosts (eg, you can only take down 30 hosts if our total is 100).

Now, we will be adding self healing to the WWWs. You want to be able to fix the
4 problems we mentioned, either by fixing the host or by automatically taking
the host(s) out of rotation.

Obviously the first thing is that you configure consul across your hosts. We
will assume that the service name where your WWW hosts are is called "www". 

The second thing we need is a configuration file for Apollo:

```
--- 
allow_full_outage: 0
extra_service: 
  storage_one_ping:
    frequency: 30
    healthcheck: /usr/local/bin/backend_storage_ping --service one
    retries: 1
  storage_one_ping:
    frequency: 30
    healthcheck: /usr/local/bin/backend_storage_ping --service two
    retries: 1
  httpok: 
    frequency: 60
    healthcheck: /usr/local/bin/check_http
    retries: 1
  load: 
    frequency: 60
    healthcheck: /usr/local/bin/check_load
    retries: 1
heal_cmd: /usr/local/bin/healing/service_healer
heal_dryrun: 0
heal_frequency: 60
heal_on_status: critical
keep_critical_secs: 90
keep_warning_secs: 0
port: 80
service_cmd: /usr/local/bin/healing/www
service_frequency: 60
service_name: www
threshold_down: 30%
hostname: www101
colo: west
```

Going over the details of what we are telling Apollo to do:

* First, we define 4 sub-services (we will cover what they are), one for each
part that we know breaks and we want to monitor on.
* The command that will be healing the host (either restarting application or
moving traffic).
* The command that will decide if the host is healthy, here in this command you
can group and script around the other services.
* Tell it our threshold for hosts going down is 30%.

Before we start going through the steps and Apollo cases, what is a service and
a sub-service? The answer is simple: a service is the overall state of your
host, a sub-service is an Apollo feature that runs separately from your main
service command. Both main service and sub-services are registered to consul.

The services and sub-services should be registered to consul and using a TTL
configuration rather than a non-TTL. Why? With a non-TTL you let consul run your
checks and thus you remove all the work/feature of Apollo which is evaluating
the state of your cluster and backing off when things are going south. The
disadvantage of a TTL is that your services (all those commands that Apollo will
be running) need to send updates under that TTL otherwise Consul might thing
that the service is down.

Now, shall we begin?

The first time that Apollo runs, Apollo will create timers for each sub-service,
the main service and the healing. Additionally it will add some tiny
milliseconds to the services so that when they run across all your hosts they
wont run exactly at the second :00, they will run slightly off.

Most of the services will start running after Apollo start, the only exception
would be the healing, you need to wait for the first round of services (and
sub-services) to finish otherwise you might think that the services are down.

Apollo will always fork each command (script) and pass it a set of environment
variables that you can use inside your script. Those environment variables will
tell you the state of the services across all the hosts contained in your
service (www in our example).

Ideally your sub-services do not need to use those environment variables because
the purpose of them is to be independent (think of them as micro-services) but
your main service (www in our example) would possibly need to know the state of
those sub-services so that it can take the right decision.

An example of those environment variables would be:

* APOLLO_SERVICE_STATUS_STORAGE_ONE_PING-WWW
* APOLLO_SERVICE_STATUS_STORAGE_TWO_PING-WWW
* APOLLO_SERVICE_STATUS_HTTPOK-WWW
* APOLLO_SERVICE_STATUS_LOAD-WWW
* APOLLO_SERVICE_STATUS_WWW
* APOLLO_SERVICE_NAME (www in our case)
* APOLLO_DATACENTER (west in our case)
* APOLLO_RECORD (www.service.west.consul in our case)


As you can see APOLLO_SERVICE_NAME, APOLLO_DATACENTER and APOLLO_RECORD have the
values we defined in our configuration file, but what about the other ones, the
ones that mention *STATUS*? The *STATUS* ones can be split in two categories: by
the main service and by the sub-services:

* APOLLO_SERVICE_STATUS_WWW: This would have information for the main service
(remember our name is www).
* APOLLO_SERVICE_STATUS_STORAGE_ONE_PING-WWW: The sub-services will have a
naming convention that is: APOLLO_SERVICE_STATUS_$SUBSERVICE-$MAINSERVICE. Both
$SUBSERVICE and $MAINSERVICE will be in upper case and each of those environment
variables will have the information of each sub-service across all the hosts
contained in our service (www).

An example of the contents of APOLLO_SERVICE_STATUS_WWW when everything (all
your www hosts) are good:

```
status=passing,since=1465763773.17217,passing=100,passing_pct=100,any=100,any_pct=100
```

And an example of say 30 hosts failing:

```
status=passing,since=1465763773.17217,critical=30,critical_pct=30,passing=70,passing_pct=70,any=100,any_pct=100
```

The contents for subservices is similar in values.

As you can see the value of those environment variables is CSV and as a
key-value format:

* status: Shows the current status of the service
* since: Shows the timestamp of since when the service has been on that status
* passing and passing_ctl: Will show the number of hosts that are in a good state.
* any and any_pct: Will show the total number of hosts that consul knows about
that specific service regardless of status.
* critical and critical_pct: Will only show if there is any critical host, one
is the fixed number while the other is the value in terms of percent.
* warning is similar as critical.



