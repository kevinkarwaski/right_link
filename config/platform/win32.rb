#
# Copyright (c) 2009 RightScale Inc
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

begin
  require 'rubygems'
  require 'win32/dir'
rescue LoadError => e
  raise e if !!(RUBY_PLATFORM =~ /mswin/)
end

module RightScale
  class Platform
    class Win32
      class Filesystem
        def right_scale_dir
          File.join(Dir::PROGRAM_FILES, 'RightScale')
        end

        def right_link_dir
          File.join(Dir::PROGRAM_FILES, 'RightScale', 'right_link')
        end

        def right_link_certs_dir
          File.join(Dir::COMMON_APPDATA, 'RightScale', 'certs')
        end

        def right_scale_state_dir
          File.join(Dir::COMMON_APPDATA, 'RightScale', 'rightscale.d')
        end

        def cloud_metadata_dir
          File.join(Dir::COMMON_APPDATA, 'RightScale', 'spool')
        end
      end
    end
  end
end