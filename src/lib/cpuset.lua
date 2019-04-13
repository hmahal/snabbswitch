-- Use of this source code is governed by the Apache 2.0 license; see COPYING.

module(...,package.seeall)

local numa = require('lib.numa')

local CPUSet = {}

function new()
   return setmetatable({by_node={}}, {__index=CPUSet})
end

do
   local cpuset = false
   function global_cpuset()
      if not cpuset then cpuset = new() end
      return cpuset
   end
end

function CPUSet:bind_to_numa_node()
   local nodes = {}
   for node, _ in pairs(self.by_node) do table.insert(nodes, node) end
   if #nodes == 0 then
      print("No CPUs available; not binding to any NUMA node.")
   elseif #nodes == 1 then
      numa.bind_to_numa_node(nodes[1])
      print("Bound main process to NUMA node: ", nodes[1])
   else
      print("CPUs available from multiple NUMA nodes: "..table.concat(nodes, ","))
      print("Not binding to any NUMA node.")
   end
end

function CPUSet:add_from_string(cpus)
   for range in cpus:split(',') do
      local lo, hi = range:match("^%s*([^%-]*)%s*-%s*([^%-%s]*)%s*$")
      if lo == nil then lo = range:match("^%s*([^%-]*)%s*$") end
      assert(lo ~= nil, 'invalid range: '..range)
      lo = assert(tonumber(lo), 'invalid range begin: '..lo)
      assert(lo == math.floor(lo), 'invalid range begin: '..lo)
      if hi ~= nil then
         hi = assert(tonumber(hi), 'invalid range end: '..hi)
         assert(hi == math.floor(hi), 'invalid range end: '..hi)
         assert(lo < hi, 'invalid range: '..range)
      else
         hi = lo
      end
      for cpu=lo,hi do self:add(cpu) end
   end
end

function CPUSet:add(cpu)
   local node = numa.cpu_get_numa_node(cpu)
   assert(node ~= nil, 'Failed to get NUMA node for CPU: '..cpu)
   if self.by_node[node] == nil then self.by_node[node] = {} end
   assert(self.by_node[cpu] == nil, 'CPU already in set: '..cpu)
   self.by_node[node][cpu] = true
end

function CPUSet:acquire_for_pci_addresses(addrs)
   return self:acquire(numa.choose_numa_node_for_pci_addresses(addrs))
end

function CPUSet:acquire(on_node)
   for node, cpus in pairs(self.by_node) do
      if on_node == nil or on_node == node then
         for cpu, avail in pairs(cpus) do
            if avail then
               cpus[cpu] = false
               return cpu
            end
         end
      end
   end
   if on_node ~= nil then
      for node, cpus in pairs(self.by_node) do
         for cpu, avail in pairs(cpus) do
            if avail then
               print("Warning: No CPU available on local NUMA node "..on_node)
               print("Warning: Assigning CPU "..cpu.." from remote node "..node)
               cpus[cpu] = false
               return cpu
            end
         end
      end
   end
   for node, cpus in pairs(self.by_node) do
      print("Warning: All assignable CPUs in use; "
               .."leaving data-plane process without assigned CPU.")
      return
   end
   print("Warning: No assignable CPUs declared; "
            .."leaving data-plane process without assigned CPU.")
end

function CPUSet:release(cpu)
   local node = numa.cpu_get_numa_node(cpu)
   assert(node ~= nil, 'Failed to get NUMA node for CPU: '..cpu)
   for x, avail in pairs(self.by_node[node]) do
      if x == cpu then
         assert(self.by_node[node][cpu] == false)
         self.by_node[node][cpu] = true
         return
      end
   end
   error('CPU not found on NUMA node: '..cpu..', '..node)
end
