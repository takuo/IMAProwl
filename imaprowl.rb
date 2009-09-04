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
require 'imapidle' unless Net::IMAP.respond_to?("idle")

class IMAProwl

  PROWL_API_ADD = "https://prowl.weks.net/publicapi/add"

  @@conf = Hash.new
  @@logger = nil
  @@prowl_conf = nil

  attr_reader :enable
  attr_reader :idle_thread

  def initialize( global, conf )
    @@conf = global
    _prowl_conf_validate( global['Prowl'] )
    @application = conf['Application'] ? conf['Application'] : "IMAProwl"
    @user = conf['User']
    @pass = conf['Pass']
    @host = conf['Host']
    @port = conf['Port'] ? conf['Port'] : 993
    @mailbox = conf['MailBox'] ? conf['MailBox'] : "INBOX"
    @interval = conf['Interval'] ? conf['Interval'] : 20
    @length = conf['BodyLength'] ? conf['BodyLength'] - 1 : 99
    @length = 1 if @length < 0
    @priority = conf['Priority'] ? conf['Priority'] : 0
    @notified = []
    @enable = conf.has_key?('Enable') ? conf['Enable'] : true
  end

  # start() should run only once
  def start
    info "Starting..."
    connect()
    unless @imap.capability.include?( 'IDLE' )
      error "Error: #{@host} does not support IDLE."
      begin
        @imap.disconnect
      ensure
        @enable = false
        return
      end
    end
    login()
    check_unseen( false )
    idler()
  end

  def restart
    info "Restarting..."
    connect()
    login()
    check_unseen( true )
    idler()
    debug "Restarted"
  end

  def stop
    @imap.idle_done
    debug "DONE IDLE."
  end

  def status
    retried = false
    debug "Check process status..."
    begin
      if @imap.disconnected?
        @idle_thread.exit if @idle_thread.alive?
        error "socket is disconnected. trying to reconnect..."
        restart
      elsif ! @idle_thread.alive?
        error "IDLE thread is dead."
        restart
      end
      if @interval > 0 && Time.now - @idle_time > 60 * @interval
        info "encounter interval."
        stop
      end
    rescue
      @idle_thread.exit if @idle_thread.alive?
      error $!.to_s
      unless retried
        retried = true
        retry
      end
    end
  end

  private
  def _prowl_conf_validate( val )
    return if @@prowl_conf
    @@prowl_conf = val
    unless @@prowl_conf.kind_of?( Hash )
      STDERR.print "Configuration Error: Prowl section must be Hash.\n"
      exit 1
    end
    unless @@prowl_conf.has_key?( 'APIKey' )
      STDERR.print "Configuration Error: APIKey must be given.\n"
      exit 1
    end
    _init_logger()
  end

  def _init_logger
    if @@conf['LogDir']
      logdir = @@conf['LogDir']
      Dir.mkdir( logdir ) unless File.exist?( logdir )
      filename = File.join( logdir, "imaprowl.log" )
      STDOUT.puts "All logs will be written into #{filename}."
      STDOUT.flush
      @@logger = Logger.new( filename, 'daily' )
      @@logger.level = @@conf['Debug'] ? Logger::DEBUG : Logger::INFO
      @@logger.datetime_format = "%Y-%m-%dT%H:%M:%S"
    else
      @@logger = nil
      STDOUT.sync = true
      STDERR.sync = true
    end
  end

  def _log( severity, str )
    if @@logger
      @@logger.add( severity, str, @application )
    else
      format = "[%Y-%m-%dT%H:%M:%S##{Process.pid}] #{@application} - #{str}\n"
      if severity == Logger::ERROR
        STDERR.print Time.now.strftime( format )
      else
        print Time.now.strftime( format )
      end
    end
  end

  def debug( str )
    _log( Logger::DEBUG, str )
  end

  def error( str )
    _log( Logger::ERROR, str )
  end

  def info( str )
    _log( Logger::INFO, str )
  end

  def login
    return true if @logged_in
    ret = @imap.login( @user, @pass )
    if ret.name != "OK"
      error "Failed to login: user: #{@user}@#{@host}."
      return false
    end
    @imap.select( @mailbox )
    @logged_in = true
    return true
  end

  def connect
    @logged_in = false
    begin
      @imap = Net::IMAP.new( @host, @port, true, nil, false ) # don't verify cert
    rescue
      error "Error on connect()"
    end
  end

  def disconnected?
    return @imap.disconnected?
  end

  def prowl( params = {} )
    uri = URI::parse( PROWL_API_ADD )
    if @@prowl_conf['ProxyHost']
      http = Net::HTTP::Proxy( @@prowl_conf['ProxyHost'],
                               @@prowl_conf['ProxyPort'],
                               @@prowl_conf['ProxyUser'],
                               @@prowl_conf['ProxyPass']).new( uri.host,
                                                               uri.port )
    else
      http = Net::HTTP.new( uri.host, uri.port )
    end

    http.use_ssl = true
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE

    request = Net::HTTP::Post.new( uri.request_uri )
    request.content_type = "application/x-www-form-urlencoded"

    query = params.map do |key, val| "#{key}=#{URI::encode(val.to_s)}" end

    return http.request(request, query.join('&'))
  end

  def check_unseen( prowl = false )
    debug "Checking UNSEEN mail."

    unseen = @imap.search( ['UNSEEN'] )
    return unless unseen.size > 0

    unseen_set = Array.new

    data_set = @imap.fetch( unseen, "(ENVELOPE BODYSTRUCTURE BODY[1] UID)" )
    data_set.each do |data|
      attr = data.attr
      unseen_set.push attr["UID"]

      if @notified.include?( attr["UID"] )
        debug "SKIP Already notified: UID=#{attr["UID"]}"
        next
      end

      # header process
      envelope = attr["ENVELOPE"]

      from_name = envelope.from.first.name
      from_addr = "#{envelope.from.first.mailbox}@#{envelope.from.first.host}"

      from = from_name ? NKF.nkf( '-mw', from_name ) : from_addr
      subject = envelope.subject ?  NKF.nkf( '-mw', envelope.subject ): "Untitled"
      event = "#{subject} from: #{from}"

      # body process
      if attr['BODYSTRUCTURE'].kind_of?( Net::IMAP::BodyTypeMultipart )
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

      body = NKF.nkf( '-w', body )
      body = body.split(//u)[0..@length].join

      # prowling
      if prowl
        info "Prowling..."
        debug "Prowling: " + event + " " + body
        presp = prowl( :apikey=> @@prowl_conf['APIKey'],
                       :application => @application,
                       :event => event,
                       :description => body,
                       :priority => @priority
                      )
        debug "Response: #{presp.code}"
      else
        debug "Not Prowled: UID=#{attr["UID"]}"
      end

    end

    # caching
    @notified = unseen_set
  end

  def idler
    @idle_thread = Thread.start do 
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
          error "Error in idler(): #{$!}"
          ##begin
          ##  ## unlock IDLE if it still exists.
          ##  @imap.idle_done 
          ##rescue
          ##  debug "Error sending DONE."
          ##end
          debug "Exiting thread"
          Thread.current.exit
        end
        debug "idler(): Still in loop"
      end # loop
    end # Thread
  end
  
end # class

Dir.chdir(File.dirname(__FILE__))
config = YAML.load_file('config.yml')

# Create Account Thread
application = Array.new
config['Accounts'].each do |account|
  app = IMAProwl.new( config, account )
  app.start()
  application.push( app ) if app.enable
end

Signal.trap("INT") {
  application.each { |app|
    begin
      app.stop
    ensure
      sleep 1
      app.idle_thread.exit if app.idle_thread.alive?
    end
  }
  print "DEBUG: Number of Threads: #{Thread.list.size}\n"  
  exit
}

loop do
  sleep 60
  application.each do |app|
    app.status
  end
end
