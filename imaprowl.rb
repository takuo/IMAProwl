#!/usr/bin/ruby
#
# IMAProwl - Prowl notification for IMAP new mail
# Version: 1.1.0
#
# Copyright (c) 2009 Takuo Kitame.
#
# You can redistribute it and/or modify it under the same term as Ruby.
#
STDOUT.sync = true
STDERR.sync = true

$:.insert(0, File.dirname(__FILE__))

IMAPROWL_VERSION = "1.1.0"
if RUBY_VERSION < "1.9.0"
  STDERR.puts "IMAProwl #{IMAPROWL_VERSION} requires Ruby >= 1.9.0"
  exit
end

require 'optparse'
require 'uri'
require 'net/https'
require 'net/imap'
require 'yaml'
require 'logger'
require 'imapidle' unless Net::IMAP.respond_to?("idle")

class IMAProwl

  PROWL_API_ADD = "https://prowl.weks.net/publicapi/add"

  @@conf = Hash.new
  @@logger = nil
  @@prowl_conf = nil

  attr_reader :enable
  attr_reader :loop_thread

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
    @noop = conf['NOOPInterval'] ? conf['NOOPInterval'] : 30
    @subject_length = conf['SubjectLength'] ? conf['SubjectLength'] - 1 : 30
    @body_length = conf['BodyLength'] ? conf['BodyLength'] - 1 : 99
    @body_length = 1 if @body_length < 0
    @subject_length = 1 if @subject_length < 0
    @priority = conf['Priority'] ? conf['Priority'] : 0
    @notified = []
    @enable = conf.has_key?('Enable') ? conf['Enable'] : true
    @no_idle = conf.has_key?('NoIDLE') ? conf['NoIDLE'] : false
  end

  # start() should run only once
  def start
    info "Starting."
    connect()
    unless @imap.capability.include?( 'IDLE' )
      error "Error: #{@host} does not support IDLE."
      error "Falling back to no IDLE support mode."
      @no_idle = true
    end
    login()
    check_unseen( false )
    if @no_idle
      checker()
    else
      idler()
    end
  end

  def restart
    info "Restarting..."
    connect()
    login()
    if @no_idle
      checker()
    else
      check_unseen( true )
      idler()
    end
    debug "Restarted"
  end

  def stop
    unless @no_idle
      @imap.idle_done
      debug "DONE IDLE."
    end
  end

  def status
    return if @no_idle
    retried = false
    debug "Check process status..."
    begin
      if @imap.disconnected?
        @loop_thread.exit if @loop_thread.alive?
        error "socket is disconnected. trying to reconnect..."
        restart
      elsif ! @loop_thread.alive?
        error "IDLE thread is dead."
        restart
      end
      if @interval > 0 && Time.now - @idle_time > 60 * @interval
        info "encounter interval."
        stop
      end
    rescue
      @loop_thread.exit if @loop_thread.alive?
      error $!.to_s
      unless retried
        retried = true
        retry
      end
    end
  end

  private
  def post_escape( string )
    string.gsub(/([^ a-zA-Z0-9_.-]+)/) do
      '%' + $1.unpack('H2' * $1.bytesize).join('%').upcase
    end.tr(' ', '+')
  end

  def mime_decode( input, out_charset = 'utf-8' )
    while input.sub!(/(=\?[A-Za-z0-9-]+\?[BQbq]\?[^\?]+\?=)(?:(?:\r\n)?[\s\t])+(=\?[A-Za-z0-9-]+\?[BQbq]\?[^\?]+\?=)/, '\1\2')
    end
    begin
      ret = input.sub!( /=\?([A-Za-z0-9-]+)\?([BQbq])\?([^\?]+)\?=/ ) {
        charset = $1
        enc = $2.upcase
        word = $3
        debug "Decode MIME hedaer: Charset: #{charset}, Encode: #{enc}, Word: #{word}"
        word = word.unpack( { "B"=>"m*", "Q"=>"M*" }[enc] ).first
        # Iconv.conv( out_charset + "//IGNORE", charset, word )
        word.encode( out_charset, charset, :invalid=>:replace, :replace=>"." )
      }
      return ret ? mime_decode( input ) : input
    rescue
      # "Error while convert MIME string."
      error "Error while converting MIME header: #{input}"
      debug "E: #{$!}"
      return input
    end
  end

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
      @@logger = Logger.new( filename, 'daily' )
      @@logger.level = @@conf['Debug'] ? Logger::DEBUG : Logger::INFO
      @@logger.datetime_format = "%Y-%m-%dT%H:%M:%S"
    else
      @@logger = nil
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

    query = params.map do |key, val| "#{key}=#{post_escape( val.to_s )}" end

    return http.request(request, query.join('&'))
  end

  def get_text_part( struct, pos )
    if struct.kind_of?( Net::IMAP::BodyTypeMultipart )
      struct.parts.each_index do |i|
        pos.push( i+1 )
        part, pos = get_text_part( struct.parts[i], pos )
        return part, pos if part && part.media_type == "TEXT"
        pos.pop
      end
    end
    if struct.media_type == "TEXT"
      return struct, pos
    end
    return nil, pos
  end

  def check_unseen( will_prowl = false )
    debug "Checking UNSEEN mail."

    unseen = @imap.search( ['UNSEEN'] )
    if unseen.size == 0
      @notified = []
      return
    end

    unseen_set = Array.new

    data_set = @imap.fetch( unseen, "(ENVELOPE BODYSTRUCTURE UID)" )
    data_set.each do |data|
      begin
        attr = data.attr

        if @notified.include?( attr["UID"] )
          debug "SKIP Already notified: UID=#{attr["UID"]}"
          unseen_set.push attr["UID"]
          next
        end

        # header process
        envelope = attr["ENVELOPE"]

        begin
          from_name = envelope.from.first.name
          from_addr = "#{envelope.from.first.mailbox}@#{envelope.from.first.host}"

          from = from_name ? mime_decode( from_name ) : from_addr
        rescue
          error "Error: Invalid From."
          debug $!.to_s
          from = "[Invalid From]"
        end

        begin
          subject = envelope.subject ? mime_decode( envelope.subject ) : "Untitled"
          if subject.split(//u).size > @subject_length
            subject = subject.split(//u)[0..@subject_length].join + "..."
          end
        rescue
          error "Error: Invalid Subject."
          debug $!.to_s
          subject = "[Invalid Subject]"
        end

        event = "#{subject} from: #{from}"

        # body process
        begin
          part, pos = get_text_part( attr['BODYSTRUCTURE'], [] )
          if part
            section = pos.size > 0 ? pos.join('.') : "1"
            debug "Detected text part: [#{section}]"
            tmp = @imap.uid_fetch( attr['UID'], "BODY.PEEK[#{section}]" ).first
            body = tmp.attr["BODY[#{section}]"]
          else
            body = "[Body does not contain TEXT part]"
            part = attr['BODYSTRUCTURE']
            debug "No text part found."
          end

          if part.media_type != "TEXT"
            # do nothing
          elsif part.respond_to?('encoding') && part.encoding == "QUOTED-PRINTABLE"
            body = body.unpack("M*").first
          elsif part.respond_to?('encoding') && part.encoding == "BASE64"
            body = body.unpack("m*").first
          end
        
          if part.param && part.param['CHARSET'] && part.param['CHARSET'] != "UTF-8"
            debug "Convert body charset from #{part.param['CHARSET']}"
            begin
              # body = Iconv.conv( 'UTF-8//IGNORE', part.param['CHARSET'], body )
              body.encode!( "UTF-8", part.param['CHARSET'], :invalid=>:replace, :replace=>"." )
            rescue
              error "Error while converting body from #{part.param['CHARSET']}"
              debug $!.to_s
              body = "[Body contains invalid charactor]"
            end
          end

          body = body.gsub(/^[\s\t]*/, '').gsub(/^$/, '')
          if body.split(//u).size > @body_length
            body = body.split(//u)[0..@body_length].join + "..."
          end
        rescue
          error "Error: Could not parse body text"
          debug $!.to_s
          body = "[Could not parse body]"
        end

        # prowling
        if will_prowl
          info "Prowling... UID=#{attr["UID"]}"
          debug "Prowling: " + event + " " + body
          begin
            presp = prowl( :apikey=> @@prowl_conf['APIKey'],
                           :application => @application,
                           :event => event,
                           :description => body,
                           :priority => @priority
                           )
            unseen_set.push attr["UID"]  if presp && presp.code == "200"
            debug "Response: #{presp.code}"
          rescue
            error "Error while HTTP/POST process."
            debug $!
          end
        else
          unseen_set.push attr["UID"]
          debug "Not Prowled (Caching): UID=#{attr["UID"]}"
        end
      rescue
        error "Error while parsing mail: UID=#{attr["UID"]}. Skipped."
        unseen_set.push attr["UID"]
        debug $!
      end
    end
    # caching
    @notified = unseen_set
  end

  def checker
    debug "Won't use IDLE to check unseen mail."
    @loop_thread = Thread.start do
      loop do
        begin
          event = false
          @imap.synchronize do
            @imap.noop
            event = true if @imap.responses["EXISTS"][-1]
            @imap.responses.delete("EXISTS")
          end
          info "Received EXISTS." if event
          check_unseen( true ) if event
          sleep( @noop )
        rescue
          error "Error in checker(): #{$!}"
          debug "Exiting thread"
          Thread.current.exit
        end
      end # loop
    end # Thread
  end

  def idler
    @loop_thread = Thread.start do
      loop do
        begin
          event = false
          debug "Entering IDLE."
          @idle_time = Time.now
          @imap.idle do |resp|
            if resp.kind_of?( Net::IMAP::UntaggedResponse ) and
               resp.name == "EXISTS"
              event = true
              info "Received EXISTS."
              @imap.idle_done
            end
          end
          check_unseen( true ) if event
        rescue
          error "Error in idler(): #{$!}"
          debug "Exiting thread"
          Thread.current.exit
        end
        debug "idler(): Still in loop"
      end # loop
    end # Thread
  end

end # class

## __MAIN__

## command line options
ProgramConfig = Hash.new
opts = OptionParser.new
opts.on( "-c", "--config FILENAME", String, "Specify the config file." ) { |v| ProgramConfig[:config] = v }
opts.on( "-q", "--daemon",nil, "Enable daemon mode.") { |v| ProgramConfig[:daemon] = true }
opts.on( "-d", "--debug", nil, "Enable debug output." ) { |v| ProgramConfig[:debug] = true }
opts.version = IMAPROWL_VERSION
opts.program_name = "imaprowl"
opts.parse!( ARGV )

## config file
config_order = [
  File.join( ENV['HOME'], '.imaprowl.conf' ),
  File.join( Dir.pwd, 'imaprowl.conf' ),
  File.join( Dir.pwd, 'config.yml' ),
  File.join( File.dirname( __FILE__ ), 'imaprowl.conf' )
]

filename = nil
if ProgramConfig[:config]
  if File.exist?( ProgramConfig[:config] )
    filename = ProgramConfig[:config]
  else
    STDERR.print "Configuration file does not exist: #{ProgramConfig[:config]}\n"
    exit 1
  end
else
  config_order.each do |conf|
    next unless File.exist?( conf )
    filename = conf
    break
  end
end
if filename.nil?
  STDERR.print "No configuration file exist.\n"
  STDERR.print "File candidates are:\n"
  STDERR.print config_order.join("\n")
  STDERR.print "\n"
  exit 1
end

STDOUT.print "LoadConf: #{filename}\n" 
config = YAML.load_file( filename )
config["Debug"] = true if ProgramConfig[:debug]


## Daemon mode
if ProgramConfig[:daemon] || config['Daemon']
  begin
    Process.daemon( true, true )
  rescue
    STDERR.print $!
    exit 1
  end
  STDOUT.print "Daemonized. PID=#{Process.pid}\n"
end

## Create Account Thread
application = Array.new
config['Accounts'].each do |account|
  app = IMAProwl.new( config, account )
  next unless app.enable
  app.start()
  application.push( app )
end

## Signal trap
Signal.trap(:INT) {
  application.each do |app|
    app.loop_thread.exit if app.loop_thread.alive?
    app.stop
  end
  sleep 1
  exit
}
Signal.trap(:TERM) {
  application.each do |app|
    app.loop_thread.exit if app.loop_thread.alive?
    app.stop
  end
  sleep 1
  exit
}

## main loop
loop do
  sleep 60
  application.each do |app|
    app.status
  end
end

## __END__
