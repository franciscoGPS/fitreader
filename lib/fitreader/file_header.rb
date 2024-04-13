class FileHeader < FitObject
  attr_accessor :header_size, :protocol_version, :profile_version, :num_record_bytes, :valid_file, :crc

  def initialize(io)
    @header_size = io.readbyte
    pp @header_size
    @protocol_version = io.readbyte
    pp @protocol_version
    @profile_version = readbytes(io, 'v', 2)
    pp @profile_version
    @num_record_bytes = readbytes(io, 'V', 4)
    @valid_file = io.read(4) == '.FIT'
    @crc = readbytes(io, 'v', 2)
  end
end
