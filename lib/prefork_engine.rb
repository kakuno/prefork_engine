require "prefork_engine/version"
require 'proc/wait3'
require 'timeout'

class PreforkEngine
  attr_reader :signal_received
  attr_reader :manager_pid

  def initialize(options={})
    defaults = {
      "max_workers"          => 10,
      "spawn_interval"       => 0,
      "err_respawn_interval" => 1,
      "trap_signals"         => {
        "TERM" => "TERM"
      },
      "before_fork"          => nil,
      "after_fork"           => nil,
      "on_child_reap"        => nil,
    }
    @options = defaults.merge(options)
    @signal_received = ""
    @manager_pid = ""
    @generation = 0
    @_no_adjust_until = 0.0
    @in_child = false
    @worker_pids = {}
    @delayed_task = nil
    @options["trap_signals"].each do |k,kv|
      Signal.trap(k) do |signo|
        @signal_received = Signal.signame(signo)
      end
    end
    Signal.trap("CHLD") do
      #do nothing
    end
  end

  def start(&block)
    @manager_pid = $$
    @signal_received = ""
    @generation += 1
    raise "cannot start another process while you are in child process" if @in_child

    # main loop
    while @signal_received.length == 0
      action = @_no_adjust_until <= Time.now.to_f ? self._decide_action() : 0

      if action > 0
        # start a new worker
        if @options["before_fork"]
           @options["before_fork"].call(self)
        end
        pid = nil
        begin
          pid = fork
        rescue => e
          # fork failed
          warn "fork failed:#{e}"
          self._update_spawn_delay(@options["err_respawn_interval"])
          next
        end
          if pid == nil
            @in_child = true
            @options["trap_signals"].each do |k,kv|
              ## Signal.trap(k, 0) #XXX in rspec only?
              Signal.trap(k, "DEFAULT")
            end
            ## Signal.trap("CHLD", 0) #XXX in rspec only?
            Signal.trap("CHLD", "DEFAULT")
            block.call
            exit!(true)
          end
          # parent
          if @options["after_fork"]
             @options["after_fork"].call(self)
          end
          @worker_pids[pid] = @generation
          self._update_spawn_delay(@options["spawn_interval"])
      end
      if r = self._wait(action <= 0)
        self._on_child_reap(r.pid, r.status)
        if @worker_pids.delete(r.pid) == @generation && r.status != 0
          self._update_spawn_delay(@options["err_respawn_interval"])
        end
      end
    end

    # send signals to workers
    if action = self._action_for(@signal_received)
      sig = action[0]
      interval = action[1]
      if interval > 0
        pids = @worker_pids.keys.sort
        @delayed_task = proc {
          pid = pids.shift
          Process.kill(sig, pid)
          if pids.empty?
            @delayed_task = nil
            @delayed_task_at = nil
          else
            @delayed_task_at = Time.now.to_f + interval
          end
        }
        @delayed_task_at = 0.0
        @delayed_task.call
      else
        self.signal_all_children(sig)
      end
    end
    return true
  end #start

  def signal_all_children(sig)
    @worker_pids.keys.sort.each do |pid|
      Process.kill(sig,pid)
    end
  end #signal_all_children

  def num_workers
    return @worker_pids.keys.length
  end

  def _decide_action
    return 1 if self.num_workers < @options["max_workers"]
    return 0
  end #_decide_action

  def _on_child_reap(pid,status)
    if @options["on_child_reap"]
      @options["on_child_reap"].call(pid,status)
    end
  end

  def _handle_delayed_task
    while true
      return nil if !@delayed_task
      timeleft = @delayed_task_at - Time.now.to_f
      return timeleft if timeleft > 0
      @delayed_task.call
    end
  end #_handle_delayed_task

  def _action_for(sig)
    return nil if !@options["trap_signals"].has_key?(sig)
    t = @options["trap_signals"][sig]
    t = [t,0] if !t.kind_of?(Enumerable)
    return t
  end

  def wait_all_children(timeout = 0)
    wait_loop = proc {
      while !@worker_pids.keys.empty?
        if r = self._wait(true)
          if @worker_pids.delete(r.pid)
            self._on_child_reap(r.pid, r.status)
          end
        end
      end
    }
    if timeout > 0
      begin
       timeout(timeout){
         wait_loop.call
       }
     rescue Timeout::Error
       # ignore
      end
    else
      wait_loop.call()
    end
    return self.num_workers();
  end # wait_all_children

  def _update_spawn_delay(secs)
    @_no_adjust_until = secs ? Time.now.to_f + secs : 0.0
  end

  def _wait(block)
    if !block
      self._handle_delayed_task()
      return Process.wait3(Process::WNOHANG)
    else
      delayed_task_sleep = self._handle_delayed_task()
      delayed_fork_sleep = self._decide_action > 0 ? [@_no_adjust_until - Time.now.to_f,0].max : nil
      sleep_secs = [delayed_task_sleep,delayed_fork_sleep,self._max_wait].compact
      begin
        if sleep_secs.min != nil
          sleep(sleep_secs.min)
          # nonblock
          return Process.wait3(Process::WNOHANG)
        else
          #block
          return Process.wait3(0)
        end
      rescue Errno::EINTR
        # wait for timer thread?
        sleep 0.02
      rescue Errno::ECHILD
        # nothing
      end
      return nil
    end
  end #_wait

  def _max_wait
    return nil
  end

end
