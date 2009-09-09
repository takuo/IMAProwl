#
#
# This code has been copied from Ruby-1.9.2's Net::IMAP.
#
# Copyright (C) 2000  Shugo Maeda <shugo@ruby-lang.org>
#
# This library is distributed under the terms of the Ruby license.
# You can freely distribute/modify this library.
#
#

class Net::IMAP
  def idle(&response_handler)
    raise LocalJumpError, "no block given" unless response_handler

    response = nil

    synchronize do
      tag = Thread.current[:net_imap_tag] = generate_tag
      put_string "#{tag} IDLE#{CRLF}"

      begin
        add_response_handler response_handler

        @idle_done_cond = new_cond
        @idle_done_cond.wait
        @idle_done_cond = nil
      ensure
        remove_response_handler response_handler
        put_string "DONE#{CRLF}"
        response = get_tagged_response( tag, "IDLE")
      end
    end

    response
  end

  def idle_done
    synchronize do
      if @idle_done_cond.nil? 
         raise Net::IMAP::Error, 'not during IDLE'
      end
      @idle_done_cond.signal
    end
  end
end
