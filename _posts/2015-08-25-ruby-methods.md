---
layout: post
tags: ruby code TIL
---

I rediscovered a nice way to give Ruby methods a more first-class feel when wanting to pass them around them without having to worry about knowledge of where the methods are defined. Lots of languages have this concept. Take JavaScript for example:

{% highlight javascript %}

myFunc = function addTwo(arg) {
  return (arg + 2);
}

typeof myFunc;
//=> 'function'

myFunc(5);
//=> 7

{% endhighlight %}

In this way, we could pass a function to someone that wanted to use it to operate on something else

{% highlight javascript %}

function caller(arg, func) {
  func.call(this, arg)
}

caller(2, myFunc)
//=> 4

{% endhighlight %}

Most Ruby code I've seen doesn't use this same mechanism of passing functions to other functions. We, as superior beings to JS developers, have blocks after all.

{% highlight ruby %}

def caller(arg, &block)
  block.call arg
end

caller do |arg|
  puts (arg + 2)
end

#=> 2

{% endhighlight %}

But what if we want to inject behavior into a caller from another class or use the same code for different blocks? Typically this involves needing to send across an object and a symbol representing the method to call via `send` or wrapping things in lambdas or Procs. Let's set up an example:

{% highlight ruby %}

class ZipUploader
  def initialize(zip)
    @zip = zip
  end

  def upload
    Unzipper.open(@zip).each_file do |file|
      TheCloud.upload file
    end
  end
end

{% endhighlight %}

Obviously, you don't need to care how Unzipper or TheCloud work. Unzipper opens the zip files and allows for iterating over each file in the archive. `TheCloud.upload` uploads them to your favorite cloud storage provider.

Now imagine you want to do some additional processing for specific files in this archive but don't want to pollute the uploader with knowledge outside of its main responsibility of getting files to the cloud. We could do this a few different ways:

{% highlight ruby %}
class ZipUploader
  def initialize(zip)
    @zip = zip
    @callbacks = {}
  end

  def upload
    Unzipper.open(@zip).each_file do |file|
      run_callbacks(file)

      TheCloud.upload file.read
    end
  end

  # Option 1: pass a block
  def file_callback(file, &block)
    @callbacks[file] = block
  end

  private

  def run_callbacks(file)
    callback = @callbacks[file.name]
    callback.call(file) if callback
  end

  # Option 2: Pass a class and a symbol to call via `send`
  def file_callback(file, processor, action)
    @callbacks[file] = { runner: processor, method: action }
  end

  def run_callbacks(file)
    callback_defn = @callbacks[file.name]
    callback_defn[:runner].send(callback[:method], file)
  end
end

class Runner
  def initialize
    @uploader = ZipUploader.new("my_archive.zip")
  end

  def run
    # Using option 1
    uploader.file_callback("my_face.jpg") do |image|
      image = ImageMagic.superheroize(image)
    end

    # Or option 2
    uploader.file_callback("my_face.jpg", self.class, :superize)

    uploader.upload
  end

  def superize(image)
    image = ImageMagic.superheroize(image)
  end
end

{% endhighlight %}

So now, using either of the two options, as the uploader is uploading files, whenever it encounters a file called "my_face.jpg", it will make it look like I'm a superhero. Awesome!

Obviously, option 2 is more complex and not as readable. The main reason we might do something like this when dealing with a system like Resque or Sidekiq, where you need jobs to be able to serialize callback info into Redis. You'd be better off storing class/method pairs over trying to serialize actual Proc or block calls.

So back to our example, in a real world application, we might have much more complex processing or a whole bunch of processors:

{% highlight ruby %}

uploader.file_callback("*_avatar.jpg") do |image|
  image = ImageMagic.resize(image, width: 80, height: 80)
end

uploader.file_callback("*_retina.tif") do |image|
  image = ImageMagic.enhance(image)
end

# and so on...

{% endhighlight %}

That adds a lot of block code to wherever we're setting up the uploader callbacks. What if we could just pass functions to our callback definitions? We _could_ define these all as lamdas or Procs:

{% highlight ruby %}

RESIZER = -> (img) { img = ImageMagic.resize(img, width: 80, height: 80) }
RETINIZER = Proc.new {|img| image = ImageMagic.enhance(image) }

uploader.file_callback("*_avatar.jpg", RESIZER)
uploader.file_callback("*_retina.tif", RETINIZER)

{% endhighlight %}

But that feels kind of ugly and un-Ruby. Well with `method` you can actually extract methods from a class and pass them to a function.

{% highlight ruby %}

def resize(image)
  image = ImageMagic.resize(image, width: 80, height: 80)
end

def retinize(image)
  image = ImageMagic.enhance(image)
end

uploader.file_callback "*_avatar.jpg", &method(:resize)
uploader.file_callback "*_retina.tif", &method(:retinize)

{% endhighlight %}

The cool thing about this is you can even extract your image processing methods to a class of some kind, responsible for different processing types and still extract the functions and pass them to a call requiring a block.

{% highlight ruby %}

class ImageHandlers
  def resize(image)
    image = ImageMagic.resize(image, width: 80, height: 80)
  end

  def retinize(image)
    image = ImageMagic.enhance(image)
  end
end

uploader.file_callback "*_avatar.jpg", &ImageHandlers.instance_method(:resize)
uploader.file_callback "*_retina.tif", &ImageHandlers.instance_method(:retinize)

{% endhighlight %}

What this `method`... uh... method returns is an instance of Ruby's [`Method`](http://ruby-doc.org/core-2.2.3/Method.html) class. This class has a number of useful methods that you can use to build out much more functional-esque code. `instance_method` does the same thing for a class's instance methods, only it returns an `UnboundMethod` instance, which is mostly the same thing, but with the added abilities to check things like `super_method` references and rebind to a different context or class/module.

If we wanted to use these `Method` objects to serialize to Redis, we could kinda fake it in the callback definition method, instead of storing the actual `Method` instance, we could serialize it using info we have available:

{% highlight ruby %}

# callback is the Method we extract
def file_callback(file, callback)
  # holds the callback reference in a string: "Class#method"
  @callbacks[file] = "#{callback.owner}##{callback.original_name}"
end

def run_callbacks(file)
  callback_defn = @callbacks[file.name]
  klass, meth = callback_defn.split('#')

  callback = klass.constantize.instance_method(meth)
  callback.send(file)

  # or just
  klass.constantize.send(meth, file)
end

{% endhighlight %}

This would allow you to serialize callbacks if need be. This will still allow you to pass methods as parameters in the calling code, allowing you to simply define methods on your class and pass them to the processor.

## Subnotes

> Like subtweeting, but for blog posts

{% highlight ruby %}

class Processor
  def plus_two(arg)
    arg + 2
  end
end

class Runner
  def block_run(arg, &block)
    yield arg
  end

  def sender(arg, cls, mth)
    cls.send mth, arg
  end
end

lambda = -> (arg) { arg + 2 }
proc = Proc.new {|arg| arg + 2 }

processor = Processor.new
runner = Runner.new

meth = processor.method(:plus_two)
rebinder = Processor.new
rebound = meth.unbind.bind rebinder

Benchmark.ips do |test|
  test.report("Direct calls") { processor.plus_two(2) }
  test.report("Via send") { runner.sender(2, processor, :plus_two) }
  test.report("Blocks") { runner.block_run(2) {|arg| arg + 2 } }
  test.report("Lambda") { runner.block_run(2, &lambda) }
  test.report("Proc") { runner.block_run(2, &proc) }
  test.report("Method") { runner.block_run(2, &meth) }
  test.report("Rebound direct call") { rebinder.plus_two(2) }
  test.report("Rebound method") { runner.block_run(2, &rebound) }

  test.compare!
end


{% endhighlight %}

{% highlight text %}

Calculating -------------------------------------
        Direct calls   135.058k i/100ms
            Via send   125.582k i/100ms
              Blocks    79.429k i/100ms
              Lambda   129.758k i/100ms
                Proc   122.336k i/100ms
              Method    60.091k i/100ms
 Rebound direct call   139.934k i/100ms
      Rebound method    59.337k i/100ms
-------------------------------------------------
        Direct calls      7.723M (± 6.9%) i/s -     38.492M
            Via send      5.190M (± 6.6%) i/s -     25.870M
              Blocks      1.515M (± 7.4%) i/s -      7.546M
              Lambda      5.252M (± 7.2%) i/s -     26.211M
                Proc      5.446M (± 5.3%) i/s -     27.159M
              Method    998.451k (± 6.2%) i/s -      4.988M
 Rebound direct call      8.097M (± 5.7%) i/s -     40.441M
      Rebound method      1.018M (± 5.7%) i/s -      5.103M

Comparison:
 Rebound direct call:  8096886.8 i/s
        Direct calls:  7722969.7 i/s - 1.05x slower
                Proc:  5445994.0 i/s - 1.49x slower
              Lambda:  5251876.4 i/s - 1.54x slower
            Via send:  5190066.6 i/s - 1.56x slower
              Blocks:  1515285.7 i/s - 5.34x slower
      Rebound method:  1017916.6 i/s - 7.95x slower
              Method:   998451.0 i/s - 8.11x slower

{% endhighlight %}

So obviously there are some performance concerns with a number of these approaches. I'm unsure as to why, other than possibly internal Ruby VM optimizations for regular method calls. Surprisingly, a block is actually slower than passing procs/lambdas or using `send`, though probably for the same reasons that using `Method` instances are slower too. Maybe I'll dig on that in my next post!
