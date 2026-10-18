import AudioToolbox

enum ChannelParser {
    /// Splits raw packet bytes into channel messages. Skips SysEx, system messages and truncated
    /// messages; real-time bytes (0xF8+) inside a message are ignored.
    static func parse(_ raw: UnsafeRawBufferPointer) -> [MIDIChannelMessage] {
        var out: [MIDIChannelMessage] = []
        var i = 0
        while i < raw.count {
            let status = raw[i]
            i += 1
            guard status >= 0x80, status < 0xF0 else { continue }
            let need = (status & 0xF0 == 0xC0 || status & 0xF0 == 0xD0) ? 1 : 2
            var data: [UInt8] = []
            while data.count < need, i < raw.count {
                let b = raw[i]
                if b >= 0xF8 {
                    i += 1; continue
                }
                if b >= 0x80 {
                    break
                } // next message starts here
                data.append(b)
                i += 1
            }
            guard data.count == need else { continue }
            out.append(MIDIChannelMessage(status: status, data1: data[0], data2: need == 2 ? data[1] : 0, reserved: 0))
        }
        return out
    }
}
