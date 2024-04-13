require 'fitreader'
require 'byebug'
require 'yaml'


class DefinitionRecord < FitObject
  attr_reader :reserved, :global_msg_num, :num_fields, :field_definitions, :data_records, :local_num, :dev_defs

  def initialize(io, local_num, dev_field_defs = nil)
    @local_num = local_num

    # read record
    @reserved = io.readbyte
    @architecture = io.readbyte

    char = @architecture.zero? ? 'v' : 'n'
    @global_msg_num = readbytes(io, char, 2)
    num_fields = io.readbyte

    # read fields
    @field_definitions = Array.new(num_fields) { FieldDefinition.new(io) }

    unless dev_field_defs.nil?
      num_fields = io.readbyte
      @dev_defs = Array.new(num_fields) { DevFieldDefinition.new(io, dev_field_defs) }
    end
    @data_records = []
  end

  def endian
    @architecture.zero? ? :little : :big
  end

  def valid

    fd = Sdk.fields(@global_msg_num)
    return if fd.nil?
    @data_records.map do |d|
      d.valid.select { |k, _| fd.keys.include? k }.merge(d.dev_fields)
    end
  end
end



module Unpack
  def readbytes(io, char, len)
    d = io.read(len)
    byebug
    d.unpack(char).first

  end

  def read_multiple(io, char, len, size)
    if char == 'Z*'
      readbytes(io, char, len)
    else  
      multiples = len / size
      
      res = io.read(len).unpack(char * multiples)
      
      if res.length == 1
        res.first
      else
        res
      end
    end
  end

  def read_bit(byte, bit)
    (byte & MASKS[bit]) >> bit
  end

  def read_bits(byte, range)
    mask = range.first
                .downto(range.last)
                .inject(0) { |sum, i| sum + MASKS[i] }
    (byte & mask) >> range.last
  end

  MASKS = {
    7 => 0b10000000,
    6 => 0b01000000,
    5 => 0b00100000,
    4 => 0b00010000,
    3 => 0b00001000,
    2 => 0b00000100,
    1 => 0b00000010,
    0 => 0b00000001
  }.freeze
end



class DataField < FitObject
  TYPES = {
    0 => { size: 1, unpack_type: 'C', endian: 0, invalid: 255 },
    1 => { size: 1, unpack_type: 'c', endian: 0, invalid: 127 },
    2 => { size: 1, unpack_type: 'C', endian: 0, invalid: 255 },
    3 => { size: 2, unpack_type: { big: 's>', little: 's<' }, endian: 1, invalid: 32767 },
    4 => { size: 2, unpack_type: { big: 'S>', little: 'S<' }, endian: 1, invalid: 65535 },
    5 => { size: 4, unpack_type: { big: 'l>', little: 'l<' }, endian: 1, invalid: 2147483647 },
    6 => { size: 4, unpack_type: { big: 'L>', little: 'L<' }, endian: 1, invalid: 4294967295 },
    7 => { size: 1, unpack_type: 'Z*', endian: 0, invalid: 0 },
    8 => { size: 4, unpack_type: { big: 'e', little: 'g' }, endian: 1, invalid: 4294967295 },
    9 => { size: 8, unpack_type: { big: 'E', little: 'G' }, endian: 1, invalid: 18446744073709551615 },
    10 => { size: 1, unpack_type: 'C', endian: 0, invalid: 0 },
    11 => { size: 2, unpack_type: { big: 'S>', little: 'S<' }, endian: 1, invalid: 0 },
    12 => { size: 4, unpack_type: { big: 'L>', little: 'L<' }, endian: 1, invalid: 0 },
    13 => { size: 1, unpack_type: 'C', endian: 0, invalid: 0xFF },
    14 => { size: 8, unpack_type: { big: 'q>', little: 'q<' }, endian: 1, invalid: 0x7FFFFFFFFFFFFFFF },
    15 => { size: 8, unpack_type: { big: 'Q>', little: 'Q<' }, endian: 1, invalid: 0xFFFFFFFFFFFFFFFF },
    16 => { size: 8, unpack_type: nil, endian: 1, invalid: 0x0000000000000000 }
  }.freeze

  attr_reader :raw, :valid

  def initialize(io, options)
    base_num = options[:base_num]
    size = options[:size]
    arch = options[:arch]

    base = TYPES[base_num]
    
    char = base[:unpack_type]
    char = char[arch] if char.is_a?(Hash)
    pp "Reading #{char} - #{size} - #{base[:size]} - #{base[:endian]}"
    @raw = read_multiple(io, char, size, base[:size])
    pp "Raw: #{@raw}"
    @valid = check(@raw, base[:invalid])
  end

  def check(raw, invalid)
    if raw.is_a? Array
      raw.any? { |e| e != invalid }
    else
      raw != invalid
    end
  end
end



class Sdk
  @enums ||= YAML.load_file(File.join(File.dirname(__FILE__), 'enums.yml'))
  @fields ||= YAML.load_file(File.join(File.dirname(__FILE__), 'fields.yml'))
  @messages ||= YAML.load_file(File.join(File.dirname(__FILE__), 'messages.yml'))

  def self.enum(name)
    @enums[name]
  end

  def self.field(msg, field)
    @fields[msg][field]
  end

  def self.fields(msg)
    @fields[msg]
  end

  def self.message(num)
    @messages[num]
  end
end


class Message
  attr_accessor :global_num, :name, :data

  def initialize(definitions)
    @global_num = definitions[0]
    @name = Sdk.message(@global_num)
    return unless @name

    fd = Sdk.fields(@global_num)
    @data = definitions[1].map { |x| make_message(x, fd) }.flatten
  end

  private

  def make_message(definition, fields)

    return if definition.valid.nil?
    definition.valid.map do |d|
      sdk_fields = d.select { |k, v| fields.has_key?(k) }

      fil = sdk_fields.map { |k, v| process_value(fields[k], v.raw) }
      
      h = Hash[fil]
      case @global_num
      when 21
        h = process_event(h)
      when 0, 23
        h = process_deviceinfo(h)
      else
        
      end
      dev_fields = Hash[d.select { |k, v| k.is_a?(Symbol) }.map {|k,v| [k, v.raw]}]
      h.merge(dev_fields)
    end
  end

  def process_value(type, val)
    if type[:type][0..3].to_sym == :enum
      val = Sdk.enum(type[:type])[val]
    elsif type[:type] == :date_time
      
      t = Time.new(1989, 12, 31, 0, 0, 0, '+00:00').utc.to_i
      val = Time.at(val + t).utc
    elsif type[:type] == :local_date_time
      t = Time.new(1989, 12, 31, 0, 0, 0, '+02:00').utc.to_i
      val = Time.at(val + t)
    elsif type[:type] == :coordinates
      val *= (180.0 / 2**31)
    end

    unless type[:scale].zero?
      if val.is_a? Array
        val = val.map { |x| (x * 1.0) / type[:scale] }
      else
        val = (val * 1.0) / type[:scale]
      end
    end

    unless type[:offset].zero?
      if val.is_a? Array
        val.map { |x| x - type[:offset] }
      else
        val - type[:offset]
      end
    end
    [type[:name], val]
  rescue => e
    puts e
  end

  def process_event(h)
    case h[:event]
    when :rear_gear_change, :front_gear_change
      h[:data] = Array(h[:data]).pack('V*').unpack('C*')
    end
    h
  end

  def process_deviceinfo(h)
    case h[:source_type]
    when :antplus
      h[:device_type] = Sdk.enum(:antplus_device_type)[h[:value]]
    end

    case h[:manufacturer]
    when :garmin, :dynastream, :dynastream_oem
      h[:garmin_product] = Sdk.enum(:enum_garmin_product)[h[:garmin_product]]
    end
    h
  end
end



class DataRecord < FitObject
  attr_reader :fields, :global_num

  def initialize(io, definition)
    @global_num = definition.global_msg_num
    @fields = Hash[definition.field_definitions.map do |f|
      opts = {base_num: f.base_num,
              size: f.size,
              arch: definition.endian}
      [f.field_def_num, DataField.new(io, opts)]
    end]
    if definition.dev_defs
      @dev_fields = Hash[definition.dev_defs.map do |f|
        opts = {base_num: f.field_def[:base_type_id].raw,
                size: f.size,
                arch: definition.endian}
        [f.field_def[:field_name].raw.to_sym, DataField.new(io, opts)]
      end]
    end
  end

  def valid
    @fields.select { |_, v| v.valid }
  end

  def dev_fields
    if defined? @dev_fields
      @dev_fields
    else
      Hash.new
    end
  end
end


io = File.new("2024-02-23-09-01-44.fit")

# pp Fit.new(io)

@header = FileHeader.new(io)

begin
  defs = {}
  dev_field_defs = {}
  finished = []

  until ((@header.num_record_bytes + 14) - io.pos) == 0
    pp "io pos: #{io.pos}" * 10
    h = RecordHeader.new(io)
    if h.definition?
      if h.has_dev_defs?
        pp "DEV DEFS FOUND" * 100
      end
      pp "inside DEFINITION if" 
      d = DefinitionRecord.new(io, h.local_message_type)
      finished << defs[d.local_num] if defs.key? d.local_num
      defs[d.local_num] = d
      # pp defs
    elsif h.data?
      if !defs.key? h.local_message_type
        pp "KEY NOT FOUND!!!" * 1000
        
      end
      d = defs[h.local_message_type]
      data_record = DataRecord.new(io, d)
      
      d.data_records << data_record
      pp "data_record"
      pp data_record
      # end
    else
      # TODO implement timestamps
      pp "In the end of the world as we know it."
      pp h
      pp "In the end of the world as we know it."
    end
    break if io.pos > 250

  end
  finished.push(*defs.values)
  io.close
  messages = finished.group_by(&:global_msg_num)
    .map { |x| Message.new x }
    .reject do |x|
       x.nil? 
      end
  messages.each_with_index do |m, i|
    pp "Message #{i}: #{m&.name}"
    
  end
rescue => e
  puts "error: #{e}\n#{e.backtrace}"
end



