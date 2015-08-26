require 'benchmark/ips'

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
