-- Use of this source code is governed by the Apache 2.0 license; see COPYING.
module(..., package.seeall)
local ffi = require('ffi')
local app = require('core.app')
local corelib = require('core.lib')
local equal = require('core.lib').equal
local dirname = require('core.lib').dirname
local mem = require('lib.stream.mem')
local ipv6 = require('lib.protocol.ipv6')
local list = require('lib.yang.list')
local data = require('lib.yang.data')
local state = require('lib.yang.state')
local yang_util = require('lib.yang.util')
local ipv4_ntop = yang_util.ipv4_ntop
local yang = require('lib.yang.yang')
local path_mod = require('lib.yang.path')
local path_data = require('lib.yang.path_data')
local generic = require('lib.ptree.support').generic_schema_config_support
local binding_table = require("apps.lwaftr.binding_table")

local function snabb_softwire_getter(path, is_config)
   local grammar = path_data.grammar_for_schema_by_name(
      'snabb-softwire-v3', '/', is_config
   )
   return path_data.resolver(grammar, path)
end

local function ietf_softwire_br_getter(path, is_config)
   local grammar = path_data.grammar_for_schema_by_name(
      'ietf-softwire-br', '/', is_config
   )
   return path_data.resolver(grammar, path)
end

local function get_softwire_grammar(is_config)
   return path_data.grammar_for_schema_by_name(
      'snabb-softwire-v3', '/', is_config
   )
end

local function get_ietf_bind_instance_grammar(is_config)
   return path_data.grammar_for_schema_by_name(
      'ietf-softwire-br', '/br-instances/binding/bind-instance', is_config
   )
end

local function get_ietf_softwire_grammar(is_config)
   return path_data.grammar_for_schema_by_name(
      'ietf-softwire-br',
      '/br-instances/binding/bind-instance/binding-table/binding-entry',
      is_config
   )
end

-- Packs snabb-softwire-v3 softwire entry into softwire and PSID blob
--
-- The data plane stores a separate table of psid maps and softwires. It
-- requires that we give it a blob it can quickly add. These look rather
-- similar to snabb-softwire-v1 structures however it maintains the br-address
-- on the softwire so are subtly different.
local function pack_softwire(app_graph, bt, entry)
   assert(app_graph.apps['lwaftr'])
   assert(entry.value.port_set, "Softwire lacks port-set definition")

   -- Now lets pack the stuff!
   local packed_softwire = bt.softwires.entry_type()
   packed_softwire.key.ipv4 = entry.ipv4
   packed_softwire.key.psid = entry.psid
   packed_softwire.value.b4_ipv6 = entry.b4_ipv6
   packed_softwire.value.br_address = entry.br_address

   local packed_psid_map = bt.psid_map.entry_type()
   packed_psid_map.key.addr = entry.ipv4
   if entry.port_set then
      packed_psid_map.value.psid_length = entry.port_set.psid_length
      packed_psid_map.value.shift = entry.port_set.shift
   end

   return packed_softwire, packed_psid_map
end

local function add_softwire_entry_actions(app_graph, bt, entries)
   local ret = {}
   for _, entry in ipairs(entries) do
      local psoftwire, ppsid = pack_softwire(app_graph, bt, entry)
      assert(bt:is_managed_ipv4_address(psoftwire.key.ipv4))

      local softwire_args = {'lwaftr', 'add_softwire_entry', psoftwire}
      table.insert(ret, {'call_app_method_with_blob', softwire_args})
   end
   table.insert(ret, {'commit', {}})
   return ret
end

local function remove_softwire_entry_actions(app_graph, path)
   assert(app_graph.apps['lwaftr'])
   path = path_mod.parse_path(path, get_softwire_grammar())
   local key = binding_table.softwire_key_t(path[#path].key)
   local args = {'lwaftr', 'remove_softwire_entry', key}
   -- If it's the last softwire for the corresponding psid entry, remove it.
   -- TODO: check if last psid entry and then remove.
   return {{'call_app_method_with_blob', args}, {'commit', {}}}
end

local function compute_config_actions(get_binding_table_instance,
                                      old_graph, new_graph, to_restart,
                                      verb, path, arg)
   if verb == 'add' and path == '/softwire-config/binding-table/softwire' then
      if to_restart == false then
         assert(new_graph.apps['lwaftr'])
         local bt_conf = app_graph.apps.lwaftr.arg.softwire_config.binding_table
         local bt = get_binding_table_instance(bt_conf)
         return add_softwire_entry_actions(new_graph, bt, arg)
      end
   elseif (verb == 'remove' and
           path:match('^/softwire%-config/binding%-table/softwire')) then
      return remove_softwire_entry_actions(new_graph, path)
   elseif (verb == 'set' and path == '/softwire-config/name') then
      return {}
   end
   return generic.compute_config_actions(
      old_graph, new_graph, to_restart, verb, path, arg)
end

local function update_mutable_objects_embedded_in_app_initargs(
      in_place_dependencies, app_graph, schema_name, verb, path, arg)
   if verb == 'add' and path == '/softwire-config/binding-table/softwire' then
      return in_place_dependencies
   elseif (verb == 'remove' and
           path:match('^/softwire%-config/binding%-table/softwire')) then
      return in_place_dependencies
   else
      return generic.update_mutable_objects_embedded_in_app_initargs(
         in_place_dependencies, app_graph, schema_name, verb, path, arg)
   end
end

local function compute_apps_to_restart_after_configuration_update(
      get_binding_table_instance,
      schema_name, configuration, verb, path, in_place_dependencies, arg)
   if verb == 'add' and path == '/softwire-config/binding-table/softwire' then
      -- We need to check if the softwire defines a new port-set, if so we need to
      -- restart unfortunately. If not we can just add the softwire.
      local bt = get_binding_table_instance(configuration.softwire_config.binding_table)
      local to_restart = false
      for _, entry in ipairs(arg) do
         to_restart = not bt:is_managed_ipv4_address(entry.ipv4)
      end
      if to_restart then return {} end
   elseif (verb == 'remove' and
           path:match('^/softwire%-config/binding%-table/softwire')) then
      return {}
   elseif (verb == 'set' and path == '/softwire-config/name') then
      return {}
   end
   return generic.compute_apps_to_restart_after_configuration_update(
      schema_name, configuration, verb, path, in_place_dependencies, arg)
end

local function ietf_binding_table_from_native(bt)
   local ret = get_ietf_softwire_grammar().list.new()
   local warn_lossy = false
   for i, softwire in ipairs(bt.softwire) do
      if ret[softwire.b4_ipv6] then
         -- If two entries in the native softwire table have the same key in
         -- the ietf-softwire-br schema, we omit the duplicate entry and print
         -- a load warning to inform the user of this issue.
         warn_lossy = warn_lossy or i
      else
         local entry = {
            binding_ipv6info = softwire.b4_ipv6,
            binding_ipv4_addr = softwire.ipv4,
            port_set = {
               psid_offset = softwire.port_set.reserved_ports_bit_count,
               psid_len = softwire.port_set.psid_length,
               psid = softwire.psid
            },
            br_ipv6_addr = softwire.br_address,
         }
         ret[softwire.b4_ipv6] = entry
      end
   end
   if warn_lossy then
      io.stderr:write(
         "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n"..
         "WARNING: the native configuration has softwires with non-unique\n"..
         "values for b4-ipv6. The binding-table returned through the\n"..
         "ietf-softwire-br schema is incomplete!\n"..
         "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n"
      )
   end
   return ret
end

local function native_binding_table_from_ietf(ietf)
   local _, softwire_grammar =
      snabb_softwire_getter('/softwire-config/binding-table/softwire')
   local softwire = softwire_grammar.list.new()
   local l = list.object(softwire)
   for _, entry in ipairs(ietf) do
      l:add_entry{
         ipv4=assert(entry.binding_ipv4_addr),
         psid=entry.port_set.psid,
         br_address=entry.br_ipv6_addr,
         b4_ipv6=entry.binding_ipv6info,
         port_set={
            psid_length=entry.port_set.psid_len,
            reserved_ports_bit_count=entry.port_set.psid_offset
         }
      }
   end
   return {softwire=softwire}
end

local function serialize_binding_table(bt)
   local _, grammar = snabb_softwire_getter('/softwire-config/binding-table')
   local printer = data.data_printer_from_grammar(grammar)
   return mem.call_with_output_string(printer, bt)
end

local function instance_name (config)
   return config.softwire_config.name or 'unnamed'
end

local function path_has_query(path, component, query)
   if query then
      for k, v in pairs(query) do
         if path[component].query[k] ~= v then
            return false
         end
      end
      return true
   else
      for k,v in pairs(path[component].query) do
         return true
      end
      return false
   end
end

local function path_match(path, ...)
   local patterns = {...}
   local idx = 1
   for _, pattern in ipairs(patterns) do
      for _, component in ipairs(pattern) do
         if not path[idx] or path[idx].name ~= component then
            return false
         end
         idx = idx + 1
      end
   end
   return true
end

local function ietf_softwire_br_translator ()
   local ret = {}
   local cached_config
   function ret.get_config(native_config)
      if cached_config ~= nil then return cached_config end
      local int = native_config.softwire_config.internal_interface
      local int_err = int.error_rate_limiting
      local ext = native_config.softwire_config.external_interface
      local ext_err = ext.error_rate_limiting
      local bind_instance = get_ietf_bind_instance_grammar().list.new()
      bind_instance[instance_name(native_config)] = {
         softwire_payload_mtu = int.mtu,
         softwire_path_mru = ext.mtu,
         -- FIXME: There's no equivalent of softwire-num-max in
         -- snabb-softwire-v3.
         softwire_num_max = 0xffffffff,
         enable_hairpinning = int.hairpinning,
         binding_table = {
            binding_entry = ietf_binding_table_from_native(
               native_config.softwire_config.binding_table)
         },
         icmp_policy = {
            icmpv4_errors = {
               allow_incoming_icmpv4 = ext.allow_incoming_icmp,
               generate_icmpv4_errors = ext.generate_icmp_errors,
               icmpv4_rate = math.floor(ext_err.packets / ext_err.period)
            },
            icmpv6_errors = {
               generate_icmpv6_errors = int.generate_icmp_errors,
               icmpv6_rate = math.floor(int_err.packets / int_err.period)
            }
         }
      }
      cached_config = {
         br_instances = {
            binding = {
               bind_instance = bind_instance
            }
         }
      }
      return cached_config
   end
   function ret.get_state(native_state, native_config)
      local c = native_state.softwire_state
      local traffic_stat = {
         discontinuity_time = c.discontinuity_time,
         sent_ipv4_packets = c.out_ipv4_packets,
         sent_ipv4_bytes = c.out_ipv4_bytes,
         sent_ipv6_packets = c.out_ipv6_packets,
         sent_ipv6_bytes = c.out_ipv6_bytes,
         rcvd_ipv4_packets = c.in_ipv4_packets,
         rcvd_ipv4_bytes = c.in_ipv4_bytes,
         rcvd_ipv6_packets = c.in_ipv6_packets,
         rcvd_ipv6_bytes = c.in_ipv6_bytes,
         dropped_ipv4_packets = c.drop_all_ipv4_iface_packets,
         dropped_ipv4_bytes = c.drop_all_ipv4_iface_bytes,
         dropped_ipv6_packets = c.drop_all_ipv6_iface_packets,
         dropped_ipv6_bytes = c.drop_all_ipv6_iface_bytes,
         dropped_ipv4_fragments = 0, -- FIXME
         dropped_ipv4_bytes = 0, -- FIXME
         ipv6_fragments_reassembled = c.in_ipv6_frag_reassembled,
         ipv6_fragments_bytes_reassembled = 0, -- FIXME
         out_icmpv4_error_packets = c.out_icmpv4_packets,
         out_icmpv4_error_bytes = c.out_icmpv4_bytes,
         out_icmpv6_error_packets = c.out_icmpv6_packets,
         out_icmpv6_error_bytes = c.out_icmpv6_bytes,
         dropped_icmpv4_packets = c.drop_in_by_policy_icmpv4_packets,
         dropped_icmpv4_bytes = c.drop_in_by_policy_icmpv4_bytes,
         hairpin_ipv4_bytes = c.hairpin_ipv4_bytes,
         hairpin_ipv4_packets = c.hairpin_ipv4_packets,
         active_softwire_num = 0, -- FIXME
      }
      local bind_instance = get_ietf_bind_instance_grammar(false).list.new()
      bind_instance[instance_name(native_config)] = {
         traffic_stat = traffic_stat
      }
      return {
         br_instances = {
            binding = {
               bind_instance = bind_instance
            }
         }
      }
   end
   function ret.set_config(native_config, path_str, arg)
      path = path_mod.parse_path(path_str)
      local bind_instance_path = {'br-instances', 'binding', 'bind-instance'}
      local binding_entry_path = {'binding-table', 'binding-entry'}

      if #path >= #bind_instance_path and
         not path_has_query(path, #bind_instance_path,
                            {name=instance_name(native_config)})
      then
         error(("Instance name does not match this instance (%s): %s")
               :format(instance_name(native_config),
                       path[#bind_instance_path].query.name))
      end

      -- Handle special br attributes (softwire-payload-mtu,
      -- softwire-path-mru, ..., icmp-policy).
      if #path == #bind_instance_path+1 and
         path_match(path, bind_instance_path)
      then
         local leaf = path[#path].name
         local path_tails = {
            ['softwire-payload-mtu'] = 'internal-interface/mtu',
            ['softwire-path-mru'] = 'external-interface/mtu',
            ['name'] = 'name',
            ['enable-hairpinning'] = 'internal-interface/hairpinning'
         }
         local path_tail = path_tails[leaf]
         if path_tail then
            return {{'set', {schema='snabb-softwire-v3',
                             path='/softwire-config/'..path_tail,
                             config=tostring(arg)}}}
         else
            error('unrecognized leaf: '..leaf)
         end
      elseif #path == #bind_instance_path+3 and
         path_match(path, bind_instance_path, {'icmp-policy', 'icmpv4-errors'})
      then
         local leaf = path[#path].name
         local path_tails = {
            ['allow-incoming-icmpv4'] = 'external-interface/allow-incoming-icmp',
            ['generate-icmpv4-errors'] = 'external-interface/generate-icmp-errors',
         }
         local path_tail = path_tails[leaf]
         if path_tail then
            return {{'set', {schema='snabb-softwire-v3',
                             path='/softwire-config/'..path_tail,
                             config=tostring(arg)}}}
         elseif leaf == 'icmpv4-rate' then
            local head = '/softwire-config/external-interface/error-rate-limiting'
            return {
               {'set', {schema='snabb-softwire-v3', path=head..'/packets',
                        config=tostring(arg * 2)}},
               {'set', {schema='snabb-softwire-v3', path=head..'/period',
                        config='2'}}}
         else
            error('unrecognized leaf: '..leaf)
         end
      elseif #path == #bind_instance_path+3 and
         path_match(path, bind_instance_path, {'icmp-policy', 'icmpv6-errors'})
      then
         local leaf = path[#path].name
         if leaf == 'generate-icmpv6-errors' then
            return {{'set', {schema='snabb-softwire-v3',
                             path='/softwire-config/internal-interface/generate-icmp-errors',
                             config=tostring(arg)}}}
         elseif leaf == 'icmpv6-rate' then
            local head = '/softwire-config/internal-interface/error-rate-limiting'
            return {
               {'set', {schema='snabb-softwire-v3', path=head..'/packets',
                        config=tostring(arg * 2)}},
               {'set', {schema='snabb-softwire-v3', path=head..'/period',
                        config='2'}}}
         else
            error('unrecognized leaf: '..leaf)
         end
      end

      -- Two kinds of updates: setting the whole binding table, or
      -- updating one entry.
      if path_match(path, bind_instance_path, binding_entry_path) then
         -- Setting the whole binding table.
         if #path == #bind_instance_path + #binding_entry_path and
            not path_has_query(path, #path)
         then
            local bt = native_binding_table_from_ietf(arg)
            return {{'set', {schema='snabb-softwire-v3',
                             path='/softwire-config/binding-table',
                             config=serialize_binding_table(bt)}}}
         else
            -- An update to an existing entry.  First, get the existing entry.
            local config = ret.get_config(native_config)
            local entry_path = path_str
            local entry_path_len = #bind_instance_path + #binding_entry_path
            for i=entry_path_len+1, #path do
               entry_path = dirname(entry_path)
            end
            local old = ietf_softwire_br_getter(entry_path)(config)
            -- Now figure out what the new entry should look like.
            local new
            if #path == entry_path_len then
               new = arg
            else
               new = {
                  port_set = {
                     psid_offset = old.port_set.psid_offset,
                     psid_len = old.port_set.psid_len,
                     psid = old.port_set.psid
                  },
                  binding_ipv4_addr = old.binding_ipv4_addr,
                  br_ipv6_addr = old.br_ipv6_addr
               }
               if path[entry_path_len + 1].name == 'port-set' then
                  if #path == entry_path_len + 1 then
                     new.port_set = arg
                  else
                     local k = data.normalize_id(path[#path].name)
                     new.port_set[k] = arg
                  end
               elseif path[#path].name == 'binding-ipv4-addr' then
                  new.binding_ipv4_addr = arg
               elseif path[#path].name == 'br-ipv6-addr' then
                  new.br_ipv6_addr = arg
               else
                  error('bad path element: '..path[#path].name)
               end
            end
            -- Apply changes.  Ensure  that the port-set
            -- changes are compatible with the existing configuration.
            local updates = {}
            local softwire_path = '/softwire-config/binding-table/softwire'

            -- Lets remove this softwire entry and add a new one.
            local function q(ipv4, psid)
               return string.format('[ipv4=%s][psid=%s]', ipv4_ntop(ipv4), psid)
            end
            local old_query = q(old.binding_ipv4_addr, old.port_set.psid)
            -- FIXME: This remove will succeed but the add could fail if
            -- there's already a softwire with this IPv4 and PSID.  We need
            -- to add a check here that the IPv4/PSID is not present in the
            -- binding table.
            table.insert(updates,
                         {'remove', {schema='snabb-softwire-v3',
                                     path=softwire_path..old_query}})

            local config_str = string.format([[{
               ipv4 %s;
               psid %s;
               br-address %s;
               b4-ipv6 %s;
               port-set {
                 psid-length %s;
                 reserved-ports-bit-count %s;
               }
               }]], ipv4_ntop(new.binding_ipv4_addr), new.port_set.psid,
               ipv6:ntop(new.br_ipv6_addr),
               path[entry_path_len].query['binding-ipv6info'],
               new.port_set.psid_len, new.port_set.psid_offset)
            table.insert(updates,
                         {'add', {schema='snabb-softwire-v3',
                                  path=softwire_path,
                                  config=config_str}})
            return updates
         end
      end

      -- Can't actually set the instance itself.
      -- (Or other paths not implemented above.)
      error("Unspported path: "..path_str)
   end
   function ret.add_config(native_config, path_str, data)
      local bind_instance_path = {'br-instances', 'binding', 'bind-instance'}
      local binding_entry_path = {'binding-table', 'binding-entry'}
      local path = path_mod.parse_path(path_str)

      if #path ~= #bind_instance_path + #binding_entry_path or
         not path_match(path, bind_instance_path, binding_entry_path)
      then
         error('unsupported path: '..path_str)
      end
      if not path_has_query(path, #bind_instance_path,
                            {name=instance_name(native_config)}) then
         error(("Instance name does not match this instance (%s): %s")
               :format(instance_name(native_config),
                       path[#bind_instance_path].query.name))
      end
      local config = ret.get_config(native_config)
      local ietf_bt = ietf_softwire_br_getter(path_str)(config)
      local old_bt = native_config.softwire_config.binding_table
      local new_bt = native_binding_table_from_ietf(data)
      local updates = {}
      local softwire_path = '/softwire-config/binding-table/softwire'
      local psid_map_path = '/softwire-config/binding-table/psid-map'
      -- Add softwires.
      local additions = {}
      for _, entry in ipairs(new_bt.softwire) do
         if old_bt.softwire[entry] then
            error('softwire already present in table: '..
                     ipv4_ntop(entry.ipv4)..'/'..entry.psid)
         end
         local config_str = string.format([[{
            ipv4 %s;
            psid %s;
            br-address %s;
            b4-ipv6 %s;
            port-set {
               psid-length %s;
               reserved-ports-bit-count %s;
            }
         }]], ipv4_ntop(entry.ipv4), entry.psid,
              ipv6:ntop(entry.br_address),
              ipv6:ntop(entry.b4_ipv6),
              entry.port_set.psid_length,
              entry.port_set.reserved_ports_bit_count
         )
         table.insert(additions, config_str)
      end
      table.insert(updates,
                   {'add', {schema='snabb-softwire-v3',
                            path=softwire_path,
                            config=table.concat(additions, '\n')}})
      return updates
   end
   function ret.remove_config(native_config, path_str)
      local bind_instance_path = {'br-instances', 'binding', 'bind-instance'}
      local binding_entry_path = {'binding-table', 'binding-entry'}
      local path = path_mod.parse_path(path_str)

      if #path == #bind_instance_path + #binding_entry_path and
         path_match(path, bind_instance_path, binding_entry_path)
      then
         if not path_has_query(path, #bind_instance_path,
                               {name=instance_name(native_config)}) then
            error(("Instance name does not match this instance (%s): %s")
                  :format(instance_name(native_config),
                          path[#bind_instance_path].query.name))
         end
         if not path_has_query(path, #path) then
            error('unsupported path: '..path_str)
         end
         local softwire_path = '/softwire-config/binding-table/softwire'
         local config = ret.get_config(native_config)
         local entry = ietf_softwire_br_getter(path_str)(config)
         local function q(ipv4, psid)
            return string.format('[ipv4=%s][psid=%s]', ipv4_ntop(ipv4), psid)
         end
         local query = q(entry.binding_ipv4_addr, entry.port_set.psid)
         return {{'remove', {schema='snabb-softwire-v3',
                             path=softwire_path..query}}}
      else
         return error('unsupported path: '..path_str)
      end
   end
   function ret.pre_update(native_config, verb, path, data)
      -- Given the notification that the native config is about to be
      -- updated, throw away our cached config; we'll re-make it next time.
      cached_config = nil
   end
   return ret
end

local function configuration_for_worker(worker, configuration)
   return worker.graph.apps.lwaftr.arg
end

local function compute_state_reader(schema_name)
   -- The schema has two lists which we want to look in.
   local grammar = path_data.grammar_for_schema_by_name(
      schema_name, '/', false
   )
   local instance_list_gmr = path_data.grammar_for_schema_by_name(
      schema_name, '/softwire-config/instance', false
   )
   local instance_state_gmr = path_data.grammar_for_schema_by_name(
      schema_name, '/softwire-config/instance/softwire-state', false
   )

   local base_reader = state.state_reader_from_grammar(grammar)
   local instance_state_reader = state.state_reader_from_grammar(instance_state_gmr)

   return function(pid, data)
      local counters = state.counters_for_pid(pid)
      local ret = base_reader(counters)
      ret.softwire_config.instance = instance_list_gmr.list.new()

      for device, instance in pairs(data.softwire_config.instance) do
         local instance_state = instance_state_reader(counters)
         ret.softwire_config.instance[device] = {
            softwire_state = instance_state
         }
         -- TODO: Copy queue[id].external_interface.next_hop.ip.resolved_mac.
         -- TODO: Copy queue[id].internal_interface.next_hop.ip.resolved_mac.
      end

      return ret
   end
end

local function process_states(discontinuity_time, states)
   -- We need to create a summation of all the states as well as adding all the
   -- instance specific state data to create a total in software-state.

   local instance_list_gmr = path_data.grammar_for_schema_by_name(
      'snabb-softwire-v3', '/softwire-config/instance', false
   )  

   local unified = {
      softwire_config = {instance = instance_list_gmr.list.new()},
      softwire_state = {
         discontinuity_time =
            yang_util.format_date_as_iso_8601(discontinuity_time)
      }
   }

   local function total_counter(name, softwire_stats, value)
      if softwire_stats[name] == nil then
         return value
      else
         return softwire_stats[name] + value
      end
   end

   for _, inst_config in ipairs(states) do
      for name, instance in pairs(inst_config.softwire_config.instance) do
         unified.softwire_config.instance[name] = instance
         for name, value in pairs(instance.softwire_state) do
            unified.softwire_state[name] = total_counter(
               name, unified.softwire_state, value)
         end
         break
      end
   end

   return unified
end


function get_config_support()
   -- Binding table instance cache.
   local binding_table_instance
   local function get_binding_table_instance(conf)
      if binding_table_instance == nil then
         binding_table_instance = binding_table.load(conf)
      end
      return binding_table_instance
   end
   -- Configuration discontinuity-time: this is set on startup and whenever the
   -- configuration changes.
   local discontinuity_time = os.time()
   -- Wrap some stateless support functions with isolated, stateful effects.
   local function compute_config_actions1 (...)
      -- Set discontinuity-time.
      discontinuity_time = os.time()
      return compute_config_actions(get_binding_table_instance, ...)
   end
   local function compute_apps_to_restart_after_configuration_update1 (...)
      return compute_apps_to_restart_after_configuration_update(
         get_binding_table_instance, ...)
   end
   local function process_states1 (...)
      return process_states(discontinuity_time, ...)
   end
   return {
      compute_config_actions = compute_config_actions1,
      update_mutable_objects_embedded_in_app_initargs =
         update_mutable_objects_embedded_in_app_initargs,
      compute_apps_to_restart_after_configuration_update =
         compute_apps_to_restart_after_configuration_update1,
      compute_state_reader = compute_state_reader,
      process_states = process_states1,
      configuration_for_worker = configuration_for_worker,
      translators = { ['ietf-softwire-br'] = ietf_softwire_br_translator () }
   }
end

function selftest ()
   local bind_instance_path = {'br-instances', 'binding', 'bind-instance'}
   local binding_entry_path = {'binding-table', 'binding-entry'}
   local path = path_mod.parse_path(
      "/br-instances/binding/bind-instance[name=test]/binding-table/binding-entry"
   )
   assert(#path == #bind_instance_path + #binding_entry_path)
   assert(path_match(path, bind_instance_path, binding_entry_path))
   assert(path_match(path, bind_instance_path))
   assert(not path_match(path, binding_entry_path))
   assert(path_has_query(path, #bind_instance_path))
   assert(path_has_query(path, #bind_instance_path, {name="test"}))
   assert(not path_has_query(path, #bind_instance_path, {name="foo"}))
   assert(not path_has_query(path, 1))
end
