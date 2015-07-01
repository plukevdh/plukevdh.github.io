---
layout: post
tags: rails code quirks TIL
---

After a fun bit of traipsing all over the Rails codebase, I found a few things out about bot Postgresql, Rails' schema format and Rails' convention around primary keys that I thought would be good to document for future me.

Rails has a schema format that looks similar to its migration format. Example:

{% highlight ruby %}

create_table "users", force: true do |t|
  t.citext   "email"
  t.datetime "created_at"
  t.datetime "updated_at"
  # ... etc ...
end

{% endhighlight %}

This is pretty cool unless you're doing something different from the standard conventions, like naming the primary key something different and changing its type. For example, Postgres has the `uuid` field type. This is a pretty standard key format convention for global unique identifiers (GUIDs), and, hey, let's use them!

Rails provides for a means of doing this out-of-the-box with Postgres:

{% highlight ruby %}

create_table "users", id: :uuid force: true do |t|
  # ... etc ...
end

{% endhighlight %}

Great! What does that do? Inspecting the database reveals two things:

1. It creates the column `id` of type `uuid` and makes it a `PRIMARY KEY`
2. It sets the `default` to be auto-generated via the `uuid_generate_v4()` method, which is part of the `uuid-ossp` extention in Postgres. This allows PKs to be generated on the fly uniquely, similarly to the auto-incrementing `sequence` field type.

So that's cool, and works generally for most people's use-case. But let's say for example we want to change the PK's name. Something like `my_cool_pk`. Rails provides _at least_ three ways of doing this via migrations:

{% highlight ruby %}

create_table "users", id: false, primary_key: "my_cool_pk"

# Or...

create_table "users", id: false do |t|
  t.primary_key :my_cool_pk, :uuid
  # ...
end

# Or...

create_table "users", id: false do |t|
  t.uuid :my_cool_pk, primary_key: true
  # ...
end

{% endhighlight %}

What you may notice from the first is that the PK column type gets dropped from the definition. **Super important detail**. The other two work just fine though. HOWEVER, both of the second two mechanisms, while they _**create**_ the table just fine when running migrations, the `schema.rb` that _all three methods_ generate all end up looking exactly like the first statement:

{% highlight ruby %}

create_table "users", id: false, primary_key: "my_cool_pk"

{% endhighlight %}

Which means, if you load this schema into the database, Rails will use the default PK convention of setting the column type as `sequence`. Why is this a problem?

The first problem is repeatability. The only way to create the same DB you have in development is to run all of the migrations. The `schema.rb` file has this big disclaimer at the top of the file:

> Note that this schema.rb definition is the authoritative source for your database schema. If you need to create the application database on another system, you should be using db:schema:load, not running all the migrations from scratch. The latter is a flawed and unsustainable approach (the more migrations you'll amass, the slower it'll run and the greater likelihood for issues).

> It's strongly recommended that you check this file into your version control system.

The glaring problem with this statement is that, because of the way this schema is generated for our special case, **the schema file no longer represents our database structure**. So what's a database to do?

There are two options, a good one, and a better one. The good one involves creating a table with _no primary key_, a `uuid` column, and a mix of constraints and an index that mimic the properties of `PRIMARY KEY`. Here's what that looks like in Rails migration land"

{% highlight ruby %}

create_table "users", id: false "my_cool_pk" do |t|
  t.uuid :my_cool_pk, null: false   # you can add the default of uuid_generate_v4() if you like
end

create_index :users, :my_cool_pk, unique: true

{% endhighlight %}

This basically makes `my_cool_pk` follow all the same conventions as a `PRIMARY KEY` field. You can see from the [Postgres documentation](http://www.postgresql.org/docs/9.4/static/ddl-constraints.html) that this is basically what `PRIMARY KEY` does (though some sources tell me that it is implemented with some differences). "But Luke", you say, as a responsible developer should, "what about the performance?". I'm glad you asked. I ran (albiet through Rails ActiveRecord) some quick benchmarks to see how selection over an index faired over a `PRIMARY KEY` field. The following is my test code and benchmark results.

{% highlight ruby %}

RECORD_COUNT = 10_000
user_ids = []
other_user_ids = []

RECORD_COUNT.times do
  id = SecureRandom.uuid

  user_ids << User.create.id
  other_user_ids << OtherUser.create.id
end

Benchmark.ips do |x|
  x.time = 10

  x.report('index') { User.find user_ids.sample }
  x.report('pk') { OtherUser.find other_user_ids.sample }
  x.compare!
end

# Calculating -------------------------------------
#               index    20.000  i/100ms
#                  pk    20.000  i/100ms
# -------------------------------------------------
#               index    214.927  (± 7.0%) i/s -      2.140k
#                  pk    217.380  (± 9.2%) i/s -      2.160k
#
# Comparison:
#                  pk:      217.4 i/s
#               index:      214.9 i/s - 1.01x slower

{% endhighlight %}

So the resulting performance between the two field types (`PRIMARY KEY` vs index + constraints) have negligible performance impact. So that's an option.

However, there's one other option to get Rails to cooperate: Ditch the troublesome `schema.rb`. This option is helpful if you want to still want to follow good DB practice while still using Rails' db sync mechanisms. The main one being test db preperation. Rails has/had/has again a `db:test:prepare` task which loads the test database from the schema if there are any migrations pending on the test db.

{% highlight ruby %}

task :prepare => %w(environment load_config) do
  unless ActiveRecord::Base.configurations.blank?
    db_namespace['test:load'].invoke
  end
end

{% endhighlight %}

And the `test:load` action:

{% highlight ruby %}

task :load => %w(db:test:purge) do
  case ActiveRecord::Base.schema_format
    when :ruby
      db_namespace["test:load_schema"].invoke
    when :sql
      db_namespace["test:load_structure"].invoke
  end
end

{% endhighlight %}

So Rails can use an actual SQL structure file instead of the schema file, so long as you've set `config.active_record.schema_format = :sql` in your `application.rb` config file. This, from all the investigation I've made so far, does the Right Thing™ in generating the correct `PRIMARY KEY` field with the correct uuid type.

{% highlight sql %}

CREATE TABLE users (
    my_cool_pk uuid DEFAULT uuid_generate_v4() NOT NULL
    # ... etc ...
);

ALTER TABLE ONLY users
    ADD CONSTRAINT users_pkey PRIMARY KEY (my_cool_pk);

{% endhighlight %}

This means the `db:test:load/prepare` tasks will work normally. The only thing that breaks is you can no longer use `db:schema:load`. However, the `db:structure:load` task will work just as well.

## Update

Short Twitter convo with a few Heroku engineers on the core PG team:

<blockquote class="twitter-tweet" lang="en"><p lang="und" dir="ltr"><a href="https://twitter.com/plukevdh">@plukevdh</a> yep <a href="http://t.co/9uTDYwNiZr">http://t.co/9uTDYwNiZr</a></p>&mdash; Craig Kerstiens (@craigkerstiens) <a href="https://twitter.com/craigkerstiens/status/615685827226513409">June 30, 2015</a></blockquote>

<blockquote class="twitter-tweet" data-conversation="none" lang="en"><p lang="en" dir="ltr"><a href="https://twitter.com/craigkerstiens">@craigkerstiens</a> do you know of any reason the performance would differ between the two?</p>&mdash; Luq (@plukevdh) <a href="https://twitter.com/plukevdh/status/615945185273454592">June 30, 2015</a></blockquote>

<blockquote class="twitter-tweet" data-conversation="none" lang="en"><p lang="en" dir="ltr"><a href="https://twitter.com/plukevdh">@plukevdh</a> you mean creating a PK vs. a unique index not null ?</p>&mdash; Craig Kerstiens (@craigkerstiens) <a href="https://twitter.com/craigkerstiens/status/615945420578136065">June 30, 2015</a></blockquote>

<blockquote class="twitter-tweet" data-conversation="none" lang="en"><p lang="en" dir="ltr"><a href="https://twitter.com/craigkerstiens">@craigkerstiens</a> <a href="https://twitter.com/plukevdh">@plukevdh</a> They&#39;re equivalent in how they perform.</p>&mdash; Peter Geoghegan (@petervgeoghegan) <a href="https://twitter.com/petervgeoghegan/status/615953027434831872">June 30, 2015</a></blockquote>

<script async src="//platform.twitter.com/widgets.js" charset="utf-8"></script>
