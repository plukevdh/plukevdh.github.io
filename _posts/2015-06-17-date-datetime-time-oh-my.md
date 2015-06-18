---
layout: post
title:  "Date, DateTime and Time, Oh My!"
date:   2015-06-17
tags: ruby code quirks TIL
---

TIL `DateTime` / `Time.now` does not respect app time zone settings. The`DateTime` / `Time.current` appears to be the correct (and documented) means of accessing the application's TZ-adjusted time.

{% highlight ruby %}
Time.now.zone
#=> "EDT"

Time.current.zone
#=> "UTC"
{% endhighlight %}


The "equivalent" `Date.today` is also unpredictable:

{% highlight ruby %}
Time.now
#=> 2015-06-17 23:17:33 -0400

Time.current
#=> Thu, 18 Jun 2015 03:17:38 UTC +00:00

Time.current.to_date
#=> Thu, 18 Jun 2015

Date.today.send :zone
#=> "+00:00"

Date.today
#=> Wed, 17 Jun 2015
{% endhighlight %}

This seems to be the TZ respecting way to get just date for today:

{% highlight ruby %}
Time.current.to_date
#=> Thu, 18 Jun 2015
{% endhighlight %}

The `x.days.from_now` etc helpers do appear to respect TZ out of the box.
