require File.expand_path(File.join(File.dirname(__FILE__),'..','..','test_helper')) 


class NewRelic::Agent::StatsEngineTest < Test::Unit::TestCase
  def setup
    NewRelic::Agent.manual_start
    @engine = NewRelic::Agent.instance.stats_engine
  end
  def teardown
    @engine.harvest_timeslice_data({},{})
  end
  def test_get_no_scope
    s1 = @engine.get_stats "a"
    s2 = @engine.get_stats "a"
    s3 = @engine.get_stats "b"
    
    assert_not_nil s1
    assert_not_nil s2
    assert_not_nil s3
    
    assert s1 == s2
    assert s1 != s3
  end
  
  # The default agent configuration when running tests does not
  # install the samplers so this test just creates them and polls them
  # just like the stats_engine does.
  def test_samplers
    
    samplers = []
    cpu_sampler = NewRelic::Agent::Samplers::CpuSampler.new
    samplers << cpu_sampler unless defined? Java
    samplers << NewRelic::Agent::Samplers::MemorySampler.new 
    samplers.each { |s| s.stats_engine = @engine }
    msg = ["Running sampler at #{Time.now}"]
    @engine.instance_eval do
      poll(samplers)
      sleep 2
      msg << "Polling again at #{Time.now}, last time polled=#{cpu_sampler.last_time}"
      poll(samplers)
      sleep 2
      msg << "Polling again at #{Time.now}, last time polled=#{cpu_sampler.last_time}"
      poll(samplers)
    end
    msg << "Last time polled: #{cpu_sampler.last_time}"
    data = @engine.harvest_timeslice_data({},{})
    cpu_user = data[NewRelic::MetricSpec.new('CPU/User Time')]
    cpu_utilization = data[NewRelic::MetricSpec.new('CPU/User/Utilization')]
    memory = data[NewRelic::MetricSpec.new('Memory/Physical')]
    # might get 1, 2 or 3 stats depending on timing factors.  short intervals are skipped.
    assert_equal 2, cpu_user.stats.call_count, cpu_user.stats.inspect unless defined? Java
    assert_equal 2, cpu_utilization.stats.call_count, msg.join("; ") unless defined? Java
    assert_equal 3, memory.stats.call_count
  end
  def test_harvest
    s1 = @engine.get_stats "a"
    s2 = @engine.get_stats "c"
    
    s1.trace_call 10
    s2.trace_call 1
    s2.trace_call 3
    
    assert @engine.get_stats("a").call_count == 1
    assert @engine.get_stats("a").total_call_time == 10
    
    assert @engine.get_stats("c").call_count == 2
    assert @engine.get_stats("c").total_call_time == 4
    
    metric_data = @engine.harvest_timeslice_data({}, {}).values
    
    # after harvest, all the metrics should be reset
    assert @engine.get_stats("a").call_count == 0
    assert @engine.get_stats("a").total_call_time == 0
    
    assert @engine.get_stats("c").call_count == 0
    assert @engine.get_stats("c").total_call_time == 0
    
    metric_data = metric_data.reverse if metric_data[0].metric_spec.name != "a"
    
    assert metric_data[0].metric_spec.name == "a"
    
    assert metric_data[0].stats.call_count == 1
    assert metric_data[0].stats.total_call_time == 10
  end
  
  def test_harvest_with_merge
    s = @engine.get_stats "a"
    s.trace_call 1
    
    assert @engine.get_stats("a").call_count == 1
    
    harvest = @engine.harvest_timeslice_data({}, {})
    assert s.call_count == 0
    s.trace_call 2
    assert s.call_count == 1
    
    # this calk should merge the contents of the previous harvest,
    # so the stats for metric "a" should have 2 data points
    harvest = @engine.harvest_timeslice_data(harvest, {})
    stats = harvest.fetch(NewRelic::MetricSpec.new("a")).stats
    assert stats.call_count == 2
    assert stats.total_call_time == 3
  end
  
  def test_scope
    @engine.push_scope "scope1"
    assert @engine.peek_scope.name == "scope1"
    
    expected = @engine.push_scope "scope2"
    @engine.pop_scope expected, 0
    
    scoped = @engine.get_stats "a"
    scoped.trace_call 3
    
    assert scoped.total_call_time == 3
    unscoped = @engine.get_stats "a"
    
    assert scoped == @engine.get_stats("a")
    assert unscoped.total_call_time == 3
  end
  
  def test_scope__overlap
    @engine.transaction_name = 'orlando'
    self.class.trace_method_execution_with_scope('disney', true, false) { sleep 0.1 }
    orlando_disney = @engine.get_stats 'disney'
    
    @engine.transaction_name = 'anaheim'
    self.class.trace_method_execution_with_scope('disney', true, false) { sleep 0.1 }
    anaheim_disney = @engine.get_stats 'disney'

    disney = @engine.get_stats_no_scope "disney"
    
    assert_not_same orlando_disney, anaheim_disney
    assert_not_equal orlando_disney, anaheim_disney
    assert_equal 1, orlando_disney.call_count 
    assert_equal 1, anaheim_disney.call_count
    assert_same disney, orlando_disney.unscoped_stats
    assert_same disney, anaheim_disney.unscoped_stats
    assert_equal 2, disney.call_count
    assert_equal disney.total_call_time, orlando_disney.total_call_time + anaheim_disney.total_call_time
    
  end
  
  def test_simplethrowcase(depth=0)
    
    fail "doh" if depth == 10
    
    scope = @engine.push_scope "scope#{depth}"    
    
    begin
      test_simplethrowcase(depth+1)
    rescue StandardError => e
      if (depth != 0)
        raise e
      end
    ensure
      @engine.pop_scope scope, 0
    end
    
    if depth == 0
      assert @engine.peek_scope.nil?
    end
  end
  
  
  def test_scope_failure
    scope1 = @engine.push_scope "scope1"
    @engine.push_scope "scope2"
    
    begin
      @engine.pop_scope scope1
      fail "Didn't throw when scope push/pop mismatched"
    rescue
      # success
    end
  end
  
  def test_children_time
    t1 = Time.now
    
    expected1 = @engine.push_scope "a"
    sleep 0.1
    t2 = Time.now
    
    expected2 = @engine.push_scope "b"
    sleep 0.2
    t3 = Time.now
    
    expected = @engine.push_scope "c"
    sleep 0.3
    scope = @engine.pop_scope expected, Time.now - t3
    
    t4 = Time.now
    
    check_time_approximate 0, scope.children_time
    check_time_approximate 0.3, @engine.peek_scope.children_time
    
    sleep 0.1
    t5 = Time.now
    
    expected = @engine.push_scope "d"
    sleep 0.2
    scope = @engine.pop_scope expected, Time.now - t5
    
    t6 = Time.now
    
    check_time_approximate 0, scope.children_time
    
    scope = @engine.pop_scope expected2, Time.now - t2
    assert_equal scope.name, 'b'
    
    check_time_approximate (t4 - t3) + (t6 - t5), scope.children_time
    
    scope = @engine.pop_scope expected1, Time.now - t1
    assert_equal scope.name, 'a'
    
    check_time_approximate (t6 - t2), scope.children_time
  end
  
  def test_simple_start_transaction
    @engine.push_scope "scope"
    @engine.start_transaction
    assert @engine.peek_scope.nil?
  end 
  
  
  # test for when the scope stack contains an element only used for tts and not metrics
  def test_simple_tt_only_scope
    scope1 = @engine.push_scope "a", 0, true
    scope2 = @engine.push_scope "b", 10, false
    scope3 = @engine.push_scope "c", 20, true
    
    @engine.pop_scope scope3, 10
    @engine.pop_scope scope2, 10
    @engine.pop_scope scope1, 10
    
    assert_equal 0, scope3.children_time
    assert_equal 10, scope2.children_time
    assert_equal 10, scope1.children_time 
  end
  
  def test_double_tt_only_scope
    scope1 = @engine.push_scope "a", 0, true
    scope2 = @engine.push_scope "b", 10, false
    scope3 = @engine.push_scope "c", 20, false
    scope4 = @engine.push_scope "d", 30, true
    
    @engine.pop_scope scope4, 10
    @engine.pop_scope scope3, 10
    @engine.pop_scope scope2, 10
    @engine.pop_scope scope1, 10
    
    assert_equal 0, scope4.children_time
    assert_equal 10, scope3.children_time
    assert_equal 10, scope2.children_time
    assert_equal 10, scope1.children_time 
  end
  
  
  private 
  def check_time_approximate(expected, actual)
    assert((expected - actual).abs < 0.01, "Expected #{expected}, got #{actual}")
  end
  
end

