module(...,package.seeall)

local bit = require("bit")
local ipv4 = require("lib.protocol.ipv4")
local ipv6 = require("lib.protocol.ipv6")
local lib = require("core.lib")

local band, rshift = bit.band, bit.rshift

local function to_ipv4_string(uint32)
   return ("%i.%i.%i.%i"):format(
      rshift(uint32, 24),
      rshift(band(uint32, 0xff0000), 16),
      rshift(band(uint32, 0xff00), 8),
      band(uint32, 0xff))
end

local function to_ipv4_u32(ip)
   assert(type(ip) == "string")
   ip = ipv4:pton(ip)
   return ip[0] * 2^24 + ip[1] * 2^16 + ip[2] * 2^8 + ip[3]
end

local function inc_ipv4(uint32)
   return uint32 + 1
end

local function softwire_entry(v4addr, psid_len, b4, br_address, port_set)
   if tonumber(v4addr) then v4addr = to_ipv4_string(v4addr) end
   local softwire = "  softwire { ipv4 %s; psid %d; b4-ipv6 %s; br-address %s;"
   softwire = softwire .. " port-set { psid-length %d; }}"
   return softwire:format(v4addr, psid_len, b4, br_address, port_set.psid_len)
end

local function inc_ipv6(ipv6)
   for i = 15, 0, -1 do
      if ipv6[i] == 255 then 
         ipv6[i] = 0
      else
         ipv6[i] = ipv6[i] + 1
         break
      end
   end
   return ipv6
end

local function softwire_entries(from_ipv4, num_ips, psid_len, from_b4, port_set)
   local entries = {}
   local v4addr = to_ipv4_u32(params.from_ipv4)
   local b4 = ipv6:pton(params.from_b4)
   local n = 2^params.psid_len
   for _ = 1, params.num_ips do
      for psid = 1, n-1 do
         table.insert(
	    entries,
	    softwire_entry(v4addr, psid, ipv6:ntop(b4), port_set)
	 )
         b4 = inc_ipv6(b4)
      end
      v4addr = inc_ipv4(v4addr)
   end
   return entries
end

local function softwires(w, params)
   local v4addr = to_ipv4_u32(params.from_ipv4)
   local b4 = ipv6:pton(params.from_b4)
   local br_address = ipv6:pton(params.br_address)
   local n = 2^params.psid_len
   for _ = 1, params.num_ips do
      for psid = 1, n-1 do
         w:ln(softwire_entry(v4addr, psid, ipv6:ntop(b4),
              ipv6:ntop(br_address), params.port_set))
         b4 = inc_ipv6(b4)
      end
      v4addr = inc_ipv4(v4addr)
   end
end

local w = {}
function w:ln(...)
   io.write(...) io.write("\n")
end
function w:close()

end

function show_usage(code)
   print(require("program.lwaftr.generate_binding_table.README_inc"))
   main.exit(code)
end

function parse_args(args)
   local handlers = {}
   function handlers.o(arg)
      local fd = assert(io.open(arg, "w"), 
         ("Couldn't find %s"):format(arg))
      function w:ln(...)
         fd:write(...) fd:write("\n")
      end
      function w:close()
         fd:close()
      end
   end
   function handlers.h() show_usage(0) end
   args = lib.dogetopt(args, handlers, "ho:", { help="h" , output="o" })
   if #args < 1 or #args > 6 then show_usage(1) end
   return unpack(args)
end

function run(args)
   local from_ipv4, num_ips, br_address, from_b4, psid_len, shift = parse_args(args)
   psid_len = assert(tonumber(psid_len))
   if not shift then
      shift = 16 - psid_len
   else
      shift = assert(tonumber(shift))
   end
   assert(psid_len + shift <= 16)

   w:ln("binding-table {")
   softwires(w, {
      from_ipv4 = from_ipv4,
      num_ips = num_ips,
      from_b4 = from_b4,
      psid_len = psid_len,
      br_address = br_address,
      port_set = {
	 psid_len = psid_len,
	 shift = shift
      }
   })
   w:ln("}")
   w:close()

   main.exit(0)
end
