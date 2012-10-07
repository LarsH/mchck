require 'ftdi'

module Ftdi
  # This data comes from ftdi.h

  MPSSE_WRITE_NEG = 0x01       # Write TDI/DO on negative TCK/SK edge
  MPSSE_BITMODE = 0x02         # Write bits, not bytes
  MPSSE_READ_NEG = 0x04        # Sample TDO/DI on negative TCK/SK edge
  MPSSE_LSB = 0x08             # LSB first
  MPSSE_DO_WRITE = 0x10        # Write TDI/DO
  MPSSE_DO_READ = 0x20         # Read TDO/DI
  MPSSE_WRITE_TMS = 0x40       # Write TMS/CS

  # FTDI MPSSE commands
  SET_BITS_LOW = 0x80
  #BYTE DATA
  #BYTE Direction
  SET_BITS_HIGH = 0x82
  #BYTE DATA
  #BYTE Direction
  GET_BITS_LOW = 0x81
  GET_BITS_HIGH = 0x83
  LOOPBACK_START = 0x84
  LOOPBACK_END = 0x85
  TCK_DIVISOR = 0x86
  # H Type specific commands
  DIS_DIV_5 = 0x8a
  EN_DIV_5 = 0x8b
  EN_3_PHASE = 0x8c
  DIS_3_PHASE = 0x8d
  CLK_BITS = 0x8e
  CLK_BYTES = 0x8f
  CLK_WAIT_HIGH = 0x94
  CLK_WAIT_LOW = 0x95
  EN_ADAPTIVE = 0x96
  DIS_ADAPTIVE = 0x97
  CLK_BYTES_OR_HIGH = 0x9c
  CLK_BYTES_OR_LOW = 0x0d
  #FT232H specific commands
  DRIVE_OPEN_COLLECTOR = 0x9e
  # Value Low
  # Value HIGH #rate is 12000000/((1+value)*2)
  def self.div_value(rate)
    if rate > 6000000
      0
    else
      if 6000000/rate - 1 > 0xffff
        0xffff
      else
        6000000/rate - 1
      end
    end
  end

  # Commands in MPSSE and Host Emulation Mode
  SEND_IMMEDIATE = 0x87
  #define WAIT_ON_HIGH   0x88
  WAIT_ON_LOW = 0x89

  # Commands in Host Emulation Mode
  READ_SHORT = 0x90
  # Address_Low
  READ_EXTENDED = 0x91
  # Address High
  # Address Low
  WRITE_SHORT = 0x92
  # Address_Low
  WRITE_EXTENDED = 0x93
  # Address High
  # Address Low

  class Context
    def set_bitmode(mask, mode)
      check_result(Ftdi.ftdi_set_bitmode(ctx, mask, mode))
    end

    def latency_timer=(new_latency)
      check_result(Ftdi.ftdi_set_latency_timer(ctx, new_latency))
      new_latency
    end

    def purge_buffers!
      check_result(Ftdi.ftdi_usb_purge_buffers(ctx))
      nil
    end
  end

  attach_function :ftdi_set_bitmode, [ :pointer, :int, :int ], :int
  attach_function :ftdi_set_latency_timer, [ :pointer, :int ], :int
  attach_function :ftdi_usb_purge_buffers, [ :pointer ], :int
end


class FtdiSwd
  XFER_MODE = Ftdi::MPSSE_LSB | Ftdi::MPSSE_WRITE_NEG

  ACK_OK = 1
  ACK_WAIT = 2
  ACK_FAULT = 4

  class ProtocolError < RuntimeError
  end

  def initialize(opt = {})
    @opt = opt
    @outbuf = ""
    @inbuf = ""
    @debug = opt[:debug]

    self.speed = opt[:speed] || 1000
    @bits = 0xbc02
    @dirs = 0xff2b
    @swdoe = opt[:swdoe_data] || 0x1000

    @dev = Ftdi::Context.new
    @dev.interface = opt[:iface] || :interface_any
    @dev.usb_open_desc_index(opt[:vid] || 0, opt[:pid] || 0, opt[:desc], opt[:serial], opt[:idx] || 0)
    @dev.usb_reset
    @dev.set_bitmode(0, 0)      # reset
    @dev.set_bitmode(0, 2)      # mpsse
    set_line_mode(:out)
    @cur_dir = :out
  end

  def raw_out(seq, seqlen=nil)
    seqlen ||= seq.length * 8
    if seqlen >= 8
      write_bytes(seq[0..(seqlen / 8)])
    end
    if seqlen % 8 > 0
      write_bits(seq[-1], seqlen % 8)
    end
  end

  def flush!
    return if @outbuf.empty?
    debug 'flush', hexify(@outbuf)
    @dev.write_data(@outbuf)
    @outbuf = ""
  end

  def transact(cmd, data=nil)
    case cmd & 0x4
    when 0
      dir = :out
    else
      dir = :in
    end

    turn :out
    write_bytes cmd.chr
    turn :in
    ack = read_bits 3

    case ack
    when ACK_OK
      # empty
    when ACK_WAIT
      raise Wait
    when ACK_FAULT
      raise Fault
    else
      raise ProtocolError
    end

    case dir
    when :out
      turn :out
      write_bytes [data].pack('V')
      write_bits calc_parity(data), 1
      nil
    when :in
      data = read_word
      par = read_bits 1
      cal_par = calc_parity data
      if par != cal_par
        raise ParityError
      end
      data
    end
  end

  def calc_parity(data)
    data ^= data >> 16
    data ^= data >> 8
    data ^= data >> 4
    data ^= data >> 2
    data ^= data >> 1
    data & 1
  end

  def turn(dir)
    return if @cur_dir == dir

    if dir == :in
      set_line_mode(dir)
    end
    write_bits(0, 1)
    if dir == :out
      set_line_mode(dir)
    end

    @cur_dir = dir
  end

  def speed=(hz)
    opspeed = 12000000
    div = opspeed / hz - 2
    div = 0 if div < 0
    @speed = opspeed / (div + 2)

    @outbuf << Ftdi::EN_DIV_5
    @outbuf << Ftdi::TCK_DIVISOR
    @outbuf << (div & 0xff)
    @outbuf << (div >> 8)
  end

  def set_line_mode(dir)
    case dir
    when :in
      bits = @bits | @swdoe
    when :out
      bits = @bits & ~@swdoe
    end

    @outbuf << Ftdi::SET_BITS_LOW
    @outbuf << (bits & 0xff)
    @outbuf << (@dirs & 0xff)
    @outbuf << Ftdi::SET_BITS_HIGH
    @outbuf << (bits >> 8)
    @outbuf << (@dirs >> 8)
  end

  def write_bytes(bytes)
    return if bytes.empty?
    len = bytes.length - 1

    @outbuf << (XFER_MODE | Ftdi::MPSSE_DO_WRITE)
    @outbuf << len % 256
    @outbuf << len / 256
    @outbuf << bytes
  end

  def write_bits(byte, len)
    return if len == 0

    @outbuf << (XFER_MODE | Ftdi::MPSSE_DO_WRITE | Ftdi::MPSSE_BITMODE)
    @outbuf << len - 1
    @outbuf << byte
  end

  def read_word
    len = 4
    @outbuf << (XFER_MODE | Ftdi::MPSSE_DO_READ)
    @outbuf << (len - 1) % 256
    @outbuf << (len - 1) / 256
    flush!

    data = expect_bytes(len)
    ret = data.unpack('V').first
    debug 'read_bytes: %08x' % ret
    ret
  end

  def read_bits(len)
    return if len == 0

    @outbuf << (XFER_MODE | Ftdi::MPSSE_DO_READ | Ftdi::MPSSE_BITMODE)
    @outbuf << len - 1
    flush!

    data = expect_bytes(1)
    ret = data.unpack('C').first >> (8 - len)
    debug 'read_bits: %0*b' % [len, ret]
    ret
  end

  def expect_bytes(num)
    while @inbuf.length < num
      @inbuf << @dev.read_data
    end
    debug 'inbuf:', hexify(@inbuf)
    ret = @inbuf.byteslice(0, num)
    @inbuf = @inbuf.byteslice(num..-1)
    debug 'read:', hexify(ret)
    ret
  end

  def debug(*args)
    if @debug
      $stderr.puts args.join(' ')
    end
  end

  def hexify(str)
    str.unpack('C*').map{|e| "%02x" % e}.join(' ')
  end
end

if $0 == __FILE__
  s = FtdiSwd.new(:vid => Integer(ARGV[0]), :pid => Integer(ARGV[1]), :debug => true)

  s.raw_out(255.chr * 7)
  s.raw_out([0xe79e].pack('v'))
  s.raw_out(255.chr * 7)
  s.raw_out(0.chr)
  puts "IDCODE: %08x" % s.transact(0xa5)
end
