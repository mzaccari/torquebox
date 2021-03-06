require 'spec_helper'
require 'torquebox-messaging'

shared_examples_for 'zero downtime deploy' do |runtime_type|

  before(:each) do
    @service_queue = TorqueBox::Messaging::Queue.new('/queue/service_response')
  end

  after(:each) do
    # Drain the service response queue
    nil until @service_queue.receive(:timeout => 1).nil?
    java.lang.System.run_finalization
  end

  it 'should not reload without runtime restart' do
    visit '/reloader-rack?0'
    element = page.find_by_id('success')
    element.should_not be_nil

    seen_values = Set.new
    seen_values << element.text
    counter = 1
    while seen_values.size <= 3 && counter < 60 do
      visit "/reloader-rack?#{counter}"
      element = page.find_by_id('success')
      element.should_not be_nil
      seen_values << element.text
      counter += 1
    end

    seen_values.size.should == 1
  end

  it 'should reload with jmx runtime restart' do
    visit '/reloader-rack?0'
    element = page.find_by_id('success')
    element.should_not be_nil
    seen_values = Set.new
    seen_value = element.text
    seen_values << seen_value
    restart_counter = 1
    while seen_values.size <= 3 && restart_counter <= 3 do
      restart_runtime_with_jmx('web', "#{runtime_type}_runtime")

      counter = 1
      while seen_values.include?(seen_value) && counter <= 200 do
        visit "/reloader-rack?#{uuid}"
        element = page.find_by_id('success')
        element.should_not be_nil
        seen_value = element.text
        counter += 1
        sleep 0.5
      end

      seen_values << seen_value
      restart_counter += 1
    end

    seen_values.size.should >= 3
  end

  it 'should reload with runtime restart.txt marker' do
    visit '/reloader-rack?0'
    element = page.find_by_id('success')
    element.should_not be_nil
    seen_values = Set.new
    seen_value = element.text
    seen_values << seen_value
    restart_counter = 1
    while seen_values.size <= 3 && restart_counter <= 3 do
      restart_runtime_with_marker('restart.txt', 'web')

      counter = 1
      while seen_values.include?(seen_value) && counter <= 200 do
        visit "/reloader-rack?#{uuid}"
        element = page.find_by_id('success')
        element.should_not be_nil
        seen_value = element.text
        counter += 1
        sleep 0.5
      end

      seen_values << seen_value
      restart_counter += 1
    end

    seen_values.size.should >= 3
  end

  it 'should reload with runtime restart-web.txt marker' do
    visit '/reloader-rack?0'
    element = page.find_by_id('success')
    element.should_not be_nil
    web_seen_values = Set.new
    web_value = element.text
    web_seen_values << web_value
    service_seen_values = Set.new
    service_value = @service_queue.receive(:timeout => 1)
    service_seen_values << service_value unless service_value.nil?
    restart_counter = 1
    while web_seen_values.size <= 3 && restart_counter <= 3 do
      restart_runtime_with_marker('restart-web.txt', 'web')

      counter = 1
      while web_seen_values.include?(web_value) && counter <= 200 do
        visit "/reloader-rack?#{uuid}"
        element = page.find_by_id('success')
        element.should_not be_nil
        web_value = element.text
        service_value = @service_queue.receive(:timeout => 1)
        service_seen_values << service_value unless service_value.nil?
        counter += 1
        sleep 0.5
      end

      web_seen_values << web_value
      restart_counter += 1
    end

    web_seen_values.size.should >= 3
    service_seen_values.size.should == 0
  end

  it 'should reload with runtime restart-all.txt marker' do
    visit "/reloader-rack?#{uuid}"
    element = page.find_by_id('success')
    element.should_not be_nil
    web_seen_values = Set.new
    web_value = element.text
    web_seen_values << web_value
    service_seen_values = Set.new
    service_value = @service_queue.receive(:timeout => 1)
    service_seen_values << service_value unless service_value.nil?
    restart_counter = 1
    while (web_seen_values.size <= 3 || service_seen_values.size <= 3) && restart_counter <= 3 do
      restart_runtime_with_marker('restart-all.txt', 'web')

      counter = 1
      service_value = nil
      while (web_seen_values.include?(web_value) || service_value.nil?) && counter <= 200 do
        visit "/reloader-rack?#{uuid}"
        element = page.find_by_id('success')
        element.should_not be_nil
        web_value = element.text
        service_value = @service_queue.receive(:timeout => 1)
        counter += 1
        sleep 0.5
      end

      web_seen_values << web_value
      service_seen_values << service_value
      restart_counter += 1
    end

    web_seen_values.size.should >= 3
    service_seen_values.size.should >= 3
  end

  it 'should not drop requests while reloading' do
    seen_values = Set.new
    thread = Thread.new {
      300.times do |i|
        visit "/reloader-rack/?#{i}"
        element = page.find_by_id('success')
        element.should_not be_nil
        seen_values << element.text
        sleep 0.01
      end
    }
    10.times do
      restart_runtime_with_jmx('web', "#{runtime_type}_runtime")
      sleep 0.3
    end
    thread.join
    # We'll probably see 10 values but it depends on thread scheduling
    seen_values.size.should > 3
  end

  it 'should not deadlock with multiple request threads' do
    threads = 25.times.map do
      Thread.new {
        10.times do |i|
          uri = URI.parse("#{Capybara.app_host}/reloader-rack/")
          response = Net::HTTP.get_response(uri)
          response.code.should == '200'
          response.body.should include('success')
        end
      }
    end

    threads.each(&:join)
  end

  it 'should update service injectable' do
    visit "/reloader-rack?#{uuid}"
    element = page.find_by_id('service_version')
    element.should_not be_nil
    service_version = element.text
    @service_queue.receive(:timeout => 1)
    restart_runtime_with_jmx('services', "#{runtime_type}_runtime")
    @service_queue.receive(:timeout => 30_000) # wait until restarted
    visit "/reloader-rack?#{uuid}"
    element = page.find_by_id('service_version')
    element.should_not be_nil
    new_service_version = element.text
    new_service_version.should_not == service_version
  end

  def restart_runtime_with_jmx(pool, app)
    # Sometimes the runtime reloading can trigger a full GC and
    # when that happens things pause and can occasionally error out
    # when trying to invoke a method on the JMX mbean
    retries = 0
    begin
      mbean("torquebox.pools:name=#{pool},app=#{app}") do |runtime|
        runtime.restart
      end
    rescue Exception => ex
      retries += 1
      if retries < 5
        sleep 0.5
        retry
      else
        raise ex
      end
    end
  end

  def restart_runtime_with_marker(marker, pool)
    app_root = File.join(MUTABLE_APP_BASE_PATH, 'rack', 'reloader')
    FileUtils.mkdir_p(File.join(app_root, 'tmp'))
    marker = File.join(app_root, 'tmp', marker)
    FileUtils.touch(marker)
  end

  def uuid
    java.util.UUID.randomUUID.to_s
  end

end

describe 'shared runtime' do

  mutable_app 'rack/reloader'
  deploy <<-END.gsub(/^ {4}/,'')
    ---
    application:
      RACK_ROOT: #{File.dirname(__FILE__)}/../target/apps/rack/reloader
      RACK_ENV: production
    web:
      context: /reloader-rack
    queues:
      /queue/service_response:
        durable: false
    services:
      SimpleService:
    ruby:
      version: #{RUBY_VERSION[0,3]}
  END

  it_should_behave_like 'zero downtime deploy', 'shared'

end

describe 'bounded runtime' do

  mutable_app 'rack/reloader'
  deploy <<-END.gsub(/^ {4}/,'')
    ---
    application:
      RACK_ROOT: #{File.dirname(__FILE__)}/../target/apps/rack/reloader
      RACK_ENV: production
    web:
      context: /reloader-rack
    queues:
      /queue/service_response:
        durable: false
    services:
      SimpleService:
    pooling:
      web:
        min: 2
        max: 3
      services:
        min: 1
        max: 2
    ruby:
      version: #{RUBY_VERSION[0,3]}
  END

  it_should_behave_like 'zero downtime deploy', 'bounded'

end
