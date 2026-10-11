------------------------------------------------------------------------
--- @file abext.lua
--- @brief AB extension header.
------------------------------------------------------------------------

local ffi = require "ffi"
require "proto.template"
local initHeader = initHeader

---------------------------------------------------------------------------
---- abext constants
---------------------------------------------------------------------------

local abext = {}

abext.PROTO_ICMP = 0x01
abext.PROTO_TCP  = 0x06
abext.PROTO_UDP  = 0x11
abext.PROTO_GRE  = 0x2f
abext.PROTO_ESP  = 0x32
abext.PROTO_AH   = 0x33
abext.PROTO_SCTP = 0x84

---------------------------------------------------------------------------
---- abext header
---------------------------------------------------------------------------


abext.headerFormat = [[
    uint8_t  next_hdr;        // Next Hdr (1B)
    uint8_t  hdr_ext_len;     // Hdr. Ext. Len (1B)
    uint8_t  opt_type;        // Opt. Type (1B)
    uint8_t  opt_len;         // Opt. Len (1B)
    uint8_t  idpid;           // IDPID (1B)
    uint16_t timeout;         // Timeout (2B)
    uint8_t  eruid[7];        // ERUID (7B)
    uint8_t  padding[2];      // Padding (2B)
    uint8_t  tag[8];          // Tag (8B)
]]




--- Variable sized member
abext.headerVariableMember = nil

local abextHeader = initHeader()
abextHeader.__index = abextHeader

function abextHeader:getProtocol()
    return self.next_hdr
end

function abextHeader:getString()
	return "AB Extension Header"
end

-- next_hdr values, keep in sync with the constants above
local mapNameProto = {
	icmp = abext.PROTO_ICMP,
	udp = abext.PROTO_UDP,
	tcp = abext.PROTO_TCP, 
	esp = abext.PROTO_ESP,
	ah = abext.PROTO_AH,
	gre = abext.PROTO_GRE,
}

--- Next header name from next_hdr, used by get/dump on uncast packets
function abextHeader:resolveNextHeader()
	local proto = self:getProtocol()
	for name, _proto in pairs(mapNameProto) do
		if proto == _proto then
			return name
		end
	end
	return nil
end

------------------------------------------------------------------------
---- Metatypes
------------------------------------------------------------------------

abext.metatype = abextHeader

return abext