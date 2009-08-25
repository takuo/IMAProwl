#!/usr/bin/ruby
#
# IMAProwl - Prowl Client for IMAP/IDLE
# Version: 0.5
#
# Copyright (c) 2009 Takuo Kitame.
#
# You can redistribute it and/or modify it under the same term as Ruby.
#
$:.insert(0, File.dirname(__FILE__))
IMAPROWL_VERSION = "0.5"
if RUBY_VERSION < "1.9.0"
  STDERR.puts "IMAProwl #{IMAPROWL_VERSION} requires Ruby >= 1.9.0"
  exit
end

require 'rubygems'
require 'thread'
require 'net/imap'
require 'yaml'
require 'prowl'
require 'nkf'
require 'logger'

unless Net::IMAP.respond_to?("idle")
  require 'imapidle'
end

class IMAProwl

  attr_reader :thread
  attr_reader :logged_in
  attr_reader :idle_time
  attr_reader :interval

  def debug(str)
    @logger.add(Logger::DEBUG, str, @application) if @logger
  end

  def error(str)
    @logger.add(Logger::ERROR, str, @application) if @logger
  end

  def info(str)
    @logger.add(Logger::INFO, str, @application) if @logger
  end

  def initialize(api_key, conf)
    @api_key = api_key
    @application = conf['Application'] ? conf['Application'] : "IMAProwl"
    @user = conf['User']
    @pass = conf['Pass']
    @host = conf['Host']
    @port = conf['Port'] ? conf['Port'] : 993
    @mailbox = conf['MailBox'] ? conf['MailBox'] : "INBOX"
    @interval = conf['Interval'] ? conf['Interval'] : 20
    @length = conf['BodyLength'] ? conf['BodyLength'] - 1 : 99
    @notified = []
    connect()
    unless @imap.capability.include?('IDLE')
      error "Error: #{@host} does not support IDLE."
      return nil
    end
  end

  def set_logger(logger)
    @logger = logger
  end
  def logger=val
    @logger=val
  end

  def name
    @application
  end

  def login
    return true if @logged_in
    ret = @imap.login(@user, @pass)
    if ret.name != "OK"
      error "Failed to login: user: #{@user}@#{@host}."
      return false
    end
    @imap.select(@mailbox)
    check_unseen(false)
    @logged_in = true
    return true
  end

  def close
    @imap.logout
    @imap.close
    @logged_in = false 
  end 

  def connect
    @imap = Net::IMAP.new( @host, @port, true, nil, false ) # don't verify cert
    @logged_in = false
  end

  def disconnected?
    return @imap.disconnected?
  end

  def logout
    @imap.logout
    @imap.close
    @imap = nil
    @logged_in = false
  end

  def check_unseen(prowl = false)
    debug "Checking UNSEEN mail."
    unseen = @imap.search(['UNSEEN'])
    unseen_set = Array.new
    unseen.each do |id|
      data = @imap.fetch(id, "(ENVELOPE BODYSTRUCTURE BODY[1] UID)").first
      attr = data.attr
      unseen_set.push attr["UID"]
      if @notified.include?(attr["UID"])
        debug "SKIP Already notified: UID=%s" % [attr["UID"]]
        next
      end

      header = { :subject => 'no title', :from => 'unknown' }
      from_name = attr["ENVELOPE"].from.first.name
      from_addr = "<%s@%s>" % [ attr["ENVELOPE"].from.first.mailbox,
                              attr["ENVELOPE"].from.first.host ]
      header[:from] = from_name ? from_name : from_addr
      header[:subject] = attr["ENVELOPE"].subject ? attr["ENVELOPE"].subject : "Untitled"
      part = nil
      body = ""
      if attr['BODYSTRUCTURE'].kind_of?(Net::IMAP::BodyTypeMultipart)
        part = attr['BODYSTRUCTURE'].parts[0]
      else
        part = attr['BODYSTRUCTURE']
      end
      if part.encoding && part.encoding.upcase == "QUOTED-PRINTABLE"
        body = attr["BODY[1]"].unpack("M*").first
      elsif part.encoding && part.encoding.upcase == "BASE64"
        body = attr["BODY[1]"].unpack("m*").first
      else
        body = attr['BODY[1]']
      end
      string = NKF.nkf('-mw', header[:subject]) + " from: " +
               NKF.nkf('-mw', header[:from])
      body = NKF.nkf('-w', body)
      body = body.split(//u)[0..@length].join
      if prowl
        info "Prowling..."
        debug "Prowling: " + string + " " + body
        presp = Prowl.send( @api_key,
                            :application => @application,
                            :event => string,
                            :description => body )
        debug "Response: #{presp}"
      else
        # debug "Not Prowled: " + string + " " + body
      end
    end
    @notified = unseen_set
  end
 
  def idler
    return unless login()
    @thread = Thread.new do 
      loop do
        begin
          event = false
          debug "Entering IDLE."
          @idle_time = Time.now
          @imap.idle do |resp|
            if resp.kind_of?( Net::IMAP::UntaggedResponse ) and
               resp.name == "EXISTS"
              event = true
              debug "Received EXISTS."
              @imap.idle_done
            end
          end
          begin
            check_unseen(true) if event
          rescue
            error "Error while checking UNSEEN mail."
            error $!.to_s
            error $!.backtrace
          end
        rescue
          error "Error! #{$!}"
          connect
          login
        end
      end # loop
    end
  end
  
  def run
    info "Start."
    idler()
  end

  def stop
    @imap.idle_done
    debug "Stop IDLE."
  end
end

Dir.chdir(File.dirname(__FILE__))
config = YAML.load_file('config.yml')

# Logger
logdir = config['LogDir'] ? config['LogDir'] : "."
Dir.mkdir(logdir) unless Dir.exist?(logdir)
STDOUT.puts "All logs will be written into #{File.join(logdir, "imaprowl.log")}."
STDOUT.flush
logger = Logger.new(File.join(logdir, "imaprowl.log"), 'daily')
logger.level = config['Debug'] ? Logger::DEBUG : Logger::INFO
logger.datetime_format = "%Y-%m-%d %H:%M:%S"

# Create Account Thread
application = Array.new
config['Accounts'].each do |account|
  ip = IMAProwl.new(config['Prowl']['APIKey'], account)
  ip.logger = logger
  ip.run
  application.push(ip)
end

Signal.trap("INT") {
  application.each do |ip|
    ip.thread.exit
  end
  exit
}

loop do
  sleep 60
  application.each do |a|
    if a.interval > 0 && Time.now - a.idle_time > 60 * a.interval
      a.stop
    end
    unless a.thread.alive?
      a.error "socket is disconnected. trying to reconnect..."
      a.connect
      a.run
      a.debug "Restarted"
    end
  end
end

