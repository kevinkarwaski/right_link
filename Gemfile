source :gemcutter

#Stock gems
gem "rake", "0.8.7"
gem "amqp", "0.6.7"
gem "bunny", "0.6.0"
gem "ohai", "0.5.8"
gem "json", "1.4.6"
gem "msgpack", "0.4.4"

#RightScale-authored (or tweaked) gems
gem "chef", "0.9.14.2"
gem "process_watcher", "0.4"
gem 'right_support', '>= 0.9'
gem "right_http_connection", "1.3.0"
gem "right_scraper", "1.0.23"

#Linux-specific gems
platforms :ruby_18 do
  gem "eventmachine", "0.12.11.5"
  gem "right_popen", "1.0.9"
end

group :test do
  gem "rspec", "~> 1.3"
  gem "flexmock", "~> 0.8"
end
