import AudioToolbox

func parse(_ b: [UInt8]) -> [[UInt8]] {
    b.withUnsafeBytes { ChannelParser.parse($0) }.map { [$0.status, $0.data1, $0.data2] }
}

assert(parse([0x90, 60, 100]) == [[0x90, 60, 100]])
assert(parse([0xC0, 5]) == [[0xC0, 5, 0]])
assert(parse([0x90, 60, 100, 0x80, 60, 0]) == [[0x90, 60, 100], [0x80, 60, 0]])
assert(parse([0xF8]).isEmpty) // clock
assert(parse([0xFE]).isEmpty) // active sensing
assert(parse([0xF0, 1, 2, 3, 0xF7]).isEmpty) // SysEx
assert(parse([0x90, 60, 0xF8, 100]) == [[0x90, 60, 100]]) // real-time inside message
assert(parse([0x90, 60]).isEmpty) // truncated
assert(parse([0x90, 60, 0x80, 60, 0]) == [[0x80, 60, 0]]) // truncated, then next message
assert(parse([60, 100]).isEmpty) // stray data bytes
print("ChannelParser tests passed")
