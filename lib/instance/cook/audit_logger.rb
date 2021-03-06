#
# Copyright (c) 2009-2011 RightScale Inc
#
# Permission is hereby granted, free of charge, to any person obtaining
# a copy of this software and associated documentation files (the
# "Software"), to deal in the Software without restriction, including
# without limitation the rights to use, copy, modify, merge, publish,
# distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to
# the following conditions:
#
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
# LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
# OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
# WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

require 'logger'

module RightScale

  # Audit logger formatter
  class AuditLogFormatter < ::Logger::Formatter

    # Generate log line from given input
    def call(severity, time, progname, msg)
      sprintf("%s: %s\n", time.strftime("%H:%M:%S"), msg2str(msg))
    end

  end

  # Provides logger interface but forwards some logging to audit entry.
  # Used in combination with Chef to audit recipe execution output.
  class AuditLogger < ::Logger

    # Underlying audit id
    attr_reader :audit_id

    # Initialize audit logger, override Logger initialize since there is no need to initialize @logdev
    #
    # === Parameters
    # audit_id(Integer):: Audit id used to audit logs
    def initialize
      @progname = nil
      @level = INFO
      @default_formatter = AuditLogFormatter.new
      @formatter = nil
      @logdev = nil
    end

    # Return level as a symbol
    #
    # === Return
    # level(Symbol):: One of :debug, :info, :warn, :error or :fatal
    alias :level_orig :level
    def level
      level = { Logger::DEBUG => :debug,
                Logger::INFO  => :info,
                Logger::WARN  => :warn,
                Logger::ERROR => :error,
                Logger::FATAL => :fatal }[level_orig]
    end

    # Raw output
    #
    # === Parameters
    # msg(String):: Raw string to be appended to audit
    def <<(msg)
      AuditStub.instance.append_output(msg)
    end

    # Override Logger::add to audit instead of writing to log file
    #
    # === Parameters
    # severity(Constant):: One of Logger::DEBUG, Logger::INFO, Logger::WARN, Logger::ERROR or Logger::FATAL
    # message(String):: Message to be audited
    # progname(String):: Override default program name for that audit
    #
    # === Block
    # Call given Block if any to build message if +message+ is nil
    #
    # === Return
    # true:: Always return true
    def add(severity, message=nil, progname=nil, &block)
      severity ||= UNKNOWN
      # We don't want to audit logs that are less than our level
      return true if severity < @level
      progname ||= @progname
      if message.nil?
        if block_given?
          message = yield
        else
          message = progname
          progname = @progname
        end
      end
      return true if is_filtered?(severity, message)
      msg = format_message(format_severity(severity), Time.now, progname, message)
      case severity
      when Logger::DEBUG
        Log.debug(message)
      when Logger::INFO, Logger::WARN, Logger::UNKNOWN
        AuditStub.instance.append_output(msg)
      when Logger::ERROR
        AuditStub.instance.append_error(msg)
      when Logger::FATAL
        AuditStub.instance.append_error(msg, :category => RightScale::EventCategories::CATEGORY_ERROR)
      end
      true
    end

    # Start new audit section
    # Note: This is a special 'log' method which allows us to create audit sections before
    # running RightScripts
    #
    # === Parameters
    # title(String):: Title of new audit section, will replace audit status as well
    # options[:category](String):: Optional, must be one of RightScale::EventCategories::CATEGORIES
    #
    # === Return
    # true:: Always return true
    def create_new_section(title, options={})
      AuditStub.instance.create_new_section(title, options)
    end

    protected

    MESSAGE_FILTERS = {
      Logger::ERROR => [
        # Chef logs all recipe exceptions without first giving the caller a
        # chance to rescue and handle exceptions in a specialized manner. filter
        # any exception messages having to do with running external scripts.
        #
        # Unfortunately the three points of execution on Windows (i.e. RightScriptProvider,
        # PowershellProvider and PowershellProviderBase) all format different
        # messages so the only consistent portion is from the Chef code.
        / \(.+ line \d+\) had an error\:\n/
      ]
    }

    # Filters any message which should not appear in audits.
    #
    # === Parameters
    # severity(Constant):: One of Logger::DEBUG, Logger::INFO, Logger::WARN, Logger::ERROR or Logger::FATAL
    # message(String):: Message to be audited
    def is_filtered?(severity, message)
      if filters = MESSAGE_FILTERS[severity]
        filters.each do |filter|
          return true if filter =~ message
        end
      end
      return false
    end

  end

end
