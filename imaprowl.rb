#!/usr/bin/ruby
#
# IMAProwl - Prowl Client for IMAP/IDLE
# Version: 0.7
#
# Copyright (c) 2009 Takuo Kitame.
#
# You can redistribute it and/or modify it under the same term as Ruby.
#
$:.insert(0, File.dirname(__FILE__))
IMAPROWL_VERSION = "0.7"
if RUBY_VERSION < "1.9.0"
  STDERR.puts "IMAProwl #{IMAPROWL_VERSION} requires Ruby >= 1.9.0"
  exit
end

require 'uri'
require 'net/https'
require 'net/imap'
require 'yaml'
require 'nkf'
require 'logger'

unless Net::IMAP.respond_to?("idle")
  require 'imapidle'
end

class IMAProwl

  PROWL_API_ADD = "https://prowl.weks.net/publicapi/add"

  attr_reader :thread
  attr_reader :logged_in
  attr_reader :idle_time
  attr_reader :interval

  @@logger = nil

  def self.logger=val
    @@logger = val
  end

  def self.prowl_conf=val
    @@prowl_conf = val
    unless @@prowl_conf.kind_of?(Hash)
      STDERR.printf "Configuration Error: Prowl section must be Hash.\n"
      exit 1
    end
    unless @@prowl_conf.has_key?('APIKey')
      STDERR.printf "Configuration Error: APIKey must be given.\n"
      exit 1
    end
  end

  def log(severity, str)
    if @@logger
      @@logger.add(severity, str, @application)
    else
      if severity == Logger::ERROR
        STDERR.print Time.now.strftime("[%Y.%m.%d %H:%M:%S] #{@application} - "), str, "\n"
      else
        print Time.now.strftime("[%Y.%m.%d %H:%M:%S] #{@application} - "), str, "\n"
      end
    end
  end

  def debug(str)
    log(Logger::DEBUG, str)
  end

  def error(str)
    log(Logger::ERROR, str)
  end

  def info(str)
    log(Logger::INFO, str)
  end

  def initialize(conf)
    @application = conf['Application'] ? conf['Application'] : "IMAProwl"
    @user = conf['User']
    @pass = conf['Pass']
    @host = conf['Host']
    @port = conf['Port'] ? conf['Port'] : 993
    @mailbox = conf['MailBox'] ? conf['MailBox'] : "INBOX"
    @interval = conf['Interval'] ? conf['Interval'] : 20
    @length = conf['BodyLength'] ? conf['BodyLength'] - 1 : 99
    @priority = conf['Priority'] ? conf['Priority'] : 0
    @notified = []
    connect()
    unless @imap.capability.include?('IDLE')
      error "Error: #{@host} does not support IDLE."
      return nil
    end
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

  def prowl(params={})
    u = URI::parse(PROWL_API_ADD)
    if @@prowl_conf['ProxyHost']
      http = Net::HTTP::Proxy(@@prowl_conf['ProxyHost'],
                              @@prowl_conf['ProxyPort'],
                              @@prowl_conf['ProxyUser'],
                              @@prowl_conf['ProxyPass']).new(u.host, u.port)
    else
      http = Net::HTTP.new(u.host, u.port)
    end
    http.use_ssl = true
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    request = Net::HTTP::Post.new(u.request_uri)
    request.content_type = "application/x-www-form-urlencoded"
    query = params.map do |key, val| "#{key}=#{URI::encode(val.to_s)}" end
    return http.request(request, query.join('&'))
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
        presp = prowl( :apikey=> @@prowl_conf['APIKey'],
                       :application => @application,
                       :event => string,
                       :description => body,
                       :priority => @priority
                      )
        debug "Response: #{presp.code}"
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
          check_unseen(true) if event
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
IMAProwl.prowl_conf = config['Prowl']

# Logger
logdir = config['LogDir'] ? config['LogDir'] : nil
if logdir
  Dir.mkdir(logdir) unless Dir.exist?(logdir)
  STDOUT.puts "All logs will be written into #{File.join(logdir, "imaprowl.log")}."
  STDOUT.flush
  IMAProwl.logger = logger = Logger.new(File.join(logdir, "imaprowl.log"), 'daily')
  logger.level = config['Debug'] ? Logger::DEBUG : Logger::INFO
  logger.datetime_format = "%Y-%m-%d %H:%M:%S"
else
  STDOUT.sync = true
end

# Create Account Thread
application = Array.new
config['Accounts'].each do |account|
  a = IMAProwl.new(account)
  a.run
  application.push(a)
end

Signal.trap("INT") {
  application.each { |t| Thread.kill( t.thread ) }
  Thread.main.exit
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
