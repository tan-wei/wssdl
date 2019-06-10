--
--  Copyright 2016 diacritic <https://diacritic.io>
--
--  This file is part of wssdl <https://github.com/diacritic/wssdl>.
--
--  wssdl is free software: you can redistribute it and/or modify
--  it under the terms of the GNU General Public License as published by
--  the Free Software Foundation, either version 3 of the License, or
--  (at your option) any later version.
--
--  wssdl is distributed in the hope that it will be useful,
--  but WITHOUT ANY WARRANTY; without even the implied warranty of
--  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
--  GNU General Public License for more details.
--
--  You should have received a copy of the GNU General Public License
--  along with wssdl.  If not, see <http://www.gnu.org/licenses/>.

local ws = {}

local utils = require 'wssdl.utils'

local function make_field (fields, prefix, field)
  local len = #field

  local function get_int_ftype(name)
    return function()
      return name .. tostring(len > 32 and 64 or math.ceil(len / 8) * 8)
    end
  end

  local getftype = {

    packet          = ftypes.STRING;
    payload         = ftypes.PROTOCOL;
    string_0        = ftypes.STRINGZ;
    string          = ftypes.STRING;
    bits_number     = get_int_ftype('UINT');
    bits            = ftypes.UINT64;
    float_32        = ftypes.FLOAT;
    float_64        = ftypes.DOUBLE;
    bytes           = ftypes.BYTES;
    bool            = ftypes.BOOLEAN;
    signed_number   = get_int_ftype('INT');
    signed          = ftypes.INT64;
    unsigned_number = get_int_ftype('UINT');
    unsigned        = ftypes.UINT64;
    address_32      = ftypes.IPv4;

    address_48 = function()
      -- Older versions of wireshark do not support ethernet protofields in
      -- their lua API. See https://code.wireshark.org/review/#/c/18917/
      -- for a follow up on the patch to address this
      if utils.semver(get_version()) >= utils.semver('2.3.0') then
        return ftypes.ETHER
      else
        return ftypes.STRING
      end
    end;

    address_128 = function()
      -- Older versions of wireshark do not support ipv6 protofields in
      -- their lua API. See https://code.wireshark.org/review/#/c/18442/
      -- for a follow up on the patch to address this
      if utils.semver(get_version()) >= utils.semver('2.3.0') then
        return ftypes.IPv6
      else
        return ftypes.STRING
      end
    end;

  }

  if field._type == 'packet' then
    -- No need to deepcopy the packet definition since the parent was cloned
    local pkt = field._packet
    pkt._properties.noclone = true
    ws.make_fields(fields, pkt, prefix .. field._name .. '.')
  end

  local getter = getftype[field._type .. '_' .. type(len)]
              or getftype[field._type .. '_' .. tostring(len)]
              or getftype[field._type]

  local ftype = type(getter) == 'function' and getter() or getter
  if type(ftype) == 'string' then
    ftype = ftypes[ftype]
  end

  local format = nil
  if field._format ~= nil then
    local corr = {
      decimal     = base.DEC,
      hexadecimal = base.HEX,
      octal       = base.OCT,
    }
    format = corr[field._format]
  end

  fields[prefix .. field._name] = ProtoField.new(
      field._displayname or field._name,
      prefix .. field._name,
      ftype,
      field._valuestring,
      format,
      nil,
      field._description)

  field._ftype = ftype
end

ws.make_fields = function (fields, pkt, prefix)
  local prefix = prefix or ''

  for i, field in ipairs(pkt._definition) do
    if not field._hidden then
      make_field(fields, prefix, field)
    end
  end
end

local dissect_int_base = function(char, c64, mname)
  return function (field, buf, raw, idx, sz)
    if idx % 8 > 0 or sz % 8 > 0 then
      if sz > 64 then
        error('wssdl: Unaligned ' .. mname .. ' field ' .. utils.quote(field._name) ..
        ' is larger than 64 bits, which is not supported by wireshark.')
      end

      local fmt, fmtp
      if math.ceil(sz / 8) > 4 then
        fmt = (field._le and '<' or '>') .. c64
        fmtp = '>E'
      else
        fmt = (field._le and '<' or '>') .. char .. tostring(math.ceil(sz / 8))
        fmtp = '>I' .. tostring(math.ceil(sz / 8))
      end

      local packed = Struct.pack(fmtp, raw:bitfield(idx % 8, sz))
      return raw, Struct.unpack(fmt, packed), sz
    else
      local val
      -- Versions of wireshark prior to 2.3.0 did not implement :int() for 3-byte integers.
      -- We have to manually extract them as 2 then 1 bytes integers.
      if mname == 'int' and sz == 24 and utils.semver(get_version()) < utils.semver('2.3.0') then
        local lo, hi = raw(1,2):uint(), raw(0,1):uint()
        val = Struct.unpack((field._le and '<' or '>') .. 'I3', Struct.pack('>I1I2', hi, lo))
      else
        val = raw[(field._le and 'le_' or '') .. mname .. (sz > 32 and '64' or '')](raw)
      end
      return raw, val, sz
    end
  end
end

local dissect_type = {

  bits = function (field, buf, raw, idx, sz, reverse)
    if sz > 64 then
      error('wssdl: "' .. field._type .. '" field ' .. field._name ..
            ' is larger than 64 bits, which is not supported by wireshark.')
    end

    local start = reverse and idx - sz or idx
    return raw, raw:bitfield(start % 8, sz), sz
  end;

  string = function (field, buf, raw, idx, sz, reverse)
    local mname = 'string'
    if field._size == 0 then
      if reverse then
        error('wssdl: Null-terminated strings cannot logically be used as suffix fields.')
      end
      raw = buf(math.floor(idx / 8))
      mname = mname .. 'z'
    end
    if field._basesz == 2 then
      mname = 'u' .. mname
    end
    local val = raw[mname](raw)
    sz = #val * 8

    if field._size == 0 then
      sz = sz + field._basesz * 8
    end
    return raw, val, sz
  end;

  address_32 = function (field, buf, raw, idx, sz)
    return raw, raw:ipv4(), sz, label
  end;

  address_48 = function (field, buf, raw, idx, sz)
    local val

    -- Older versions of wireshark do not support ether protofields in
    -- their lua API. See https://code.wireshark.org/review/#/c/18917/
    -- for a follow up on the patch to address this
    if utils.semver(get_version()) < utils.semver('2.3.0') then
      val = utils.tvb_ether(raw)
      label = {(field._displayname or field._name) .. ': ', val}
    else
      val = raw:ether()
    end
    return raw, val, sz, label
  end;

  address_128 = function (field, buf, raw, idx, sz)
    local val

    -- Older versions of wireshark do not support ipv6 protofields in
    -- their lua API. See https://code.wireshark.org/review/#/c/18442/
    -- for a follow up on the patch to address this
    if utils.semver(get_version()) < utils.semver('2.3.0') then
      val = utils.tvb_ipv6(raw)
      label = {(field._displayname or field._name) .. ': ', val}
    else
      val = raw:ipv6()
    end
    return raw, val, sz, label
  end;

  bytes = function (field, buf, raw, idx, sz)
    if idx % 8 > 0 then
      error('wssdl: field ' .. utils.quote(field._name) ..
            ' is an unaligned "bytes" field, which is not supported.')
    end
    return raw, Struct.fromhex(tostring(raw:bytes())), sz
  end;

  signed = dissect_int_base('i', 'e', 'int');

  unsigned = dissect_int_base('I', 'E', 'uint');

  float = function (field, buf, raw, idx, sz)
    if idx % 8 > 0 then
      local fmt = (field._le and '<' or '>') .. (sz == 64 and 'd' or 'f')
      local packed = Struct.pack(sz == 64 and '>E' or '>I4', raw:bitfield(idx % 8, sz))
      return raw, Struct.unpack(fmt, packed), sz
    else
      local val = field._le and raw:le_float() or raw:float()
      return raw, val, sz
    end
  end;

  default = function (field, buf, raw, idx, sz)
    error('wssdl: Unknown "' .. field._type .. '" field ' .. field._name .. '.')
  end;

}

dissect_type.bool = dissect_type.bits;

ws.dissector = function (pkt, proto)

  local prop_desegment = pkt._properties.desegment

  local function tree_add_fields(pkt, prefix, tree, pktval)
    for i, field in ipairs(pkt._definition) do
      local protofield = proto.fields[prefix .. field._name]
      local labels = pktval.label[field._name] or {}
      local val = pktval.val[field._name]
      local raw = pktval.buf[field._name]
      local node

      if field._type == 'packet' then
        local pktval = { buf = raw, label = labels, val = val }
        if field._hidden then
          node = tree:add(protofield, raw._self, '', '')
        else
          node = tree:add(protofield, raw._self, '', unpack(labels))
        end
        tree_add_fields(field._packet, prefix .. field._name .. '.', node, pktval)
      elseif not field._hidden then
        node = tree:add(protofield, raw, val, unpack(labels))
      end
    end
  end

  local function dissect_pkt(pkt, start, buf, pinfo, istart, iend, reverse)
    local idx = start
    local pktval = {
      sz = {},
      buf = {},
      val = {},
      label = {}
    }
    local subdissect = {}

    local function size_of(field)
      local sz = #field

      if sz and type(sz) ~= 'number' then
        pkt:eval(pktval.val)
        sz = #field
      end

      if sz and type(sz) ~= 'number' then
        error('wssdl: Cannot evaluate size of ' .. utils.quote(field._name) ..
              ' field.')
      end

      return sz
    end

    local function align_of(field)
      local align = field._align

      if align and type(align) ~= 'number' then
        pkt:eval(pktval.val)
        align = field._align
      end

      if align and type(align) ~= 'number' then
        error('wssdl: Cannot evaluate alignment of ' .. utils.quote(field._name) ..
              ' field.')
      end

      return align or 1
    end

    local function value_of(field)
      local value = field._value

      if value and type(value) == 'table' and rawget(value, '_eval') then
        pkt:eval(pktval.val)
        value = field._value
      end

      if value and type(value) == 'table' and rawget(value, '_eval') then
        error('wssdl: Cannot evaluate field ' .. utils.quote(field._name) .. '.')
      end

      return value
    end

    local dissect_field

    local function find_valued_field_after(ifield)
      local start = buf:len() * 8
      local iend = #pkt._definition
      for i = ifield + 1, #pkt._definition do
        local field = pkt._definition[i]
        local value = value_of(field)
        if value then
          local align = align_of(field)
          local sz = size_of(field)
          local idx = idx

          if idx % align ~= 0 then
            idx = idx + (align - idx % align)
          end

          -- Find the value in the tvb
          local found = false
          while idx + sz <= buf:len() * 8 do
            local res, err = dissect_field(i, field, idx)
            if err then
              return nil, err
            end
            local raw, val, _, label = unpack(res, 1, 4)

            pktval.sz[field._name] = sz
            pktval.buf[field._name] = raw
            pktval.val[field._name] = val
            pktval.label[field._name] = label

            if val == value then
              found = true
              break
            end
            idx = idx + align
          end
          if not found then
            if not prop_desegment then
              error('wssdl: Valued field ' .. utils.quote(field._name) .. ' could not be found in the payload')
            end
            return -1
          end
          start = idx
          iend = i - 1
          break
        end
      end
      return start, iend
    end

    dissect_field = function (ifield, field, idx)
      local sz = nil
      local raw = nil
      local val = nil
      local label = nil
      local sdiss = nil

      local align = align_of(field)
      if idx % align ~= 0 then
        idx = idx + (align - idx % align)
      end

      if field._type == 'packet' then
        raw = reverse and buf(0, math.ceil(idx / 8))
                      or buf(math.floor(idx / 8))

        local istart = reverse and #field._packet._definition or 1
        local iend   = reverse and 1 or #field._packet._definition
        local start  = reverse and idx or idx % 8

        local res, err = dissect_pkt(field._packet, start, raw:tvb(), pinfo, istart, iend, reverse)
        -- Handle errors
        if err then
          return nil, err
        end

        sz, val, sdiss = unpack(res, 1, 3)
        if reverse then
          sz = -sz
        end
        local procsz = math.ceil((sz + idx % 8) / 8)
        val.buf._self = reverse and buf(math.floor(idx / 8) - procsz, procsz)
                                or buf(math.floor(idx / 8), procsz)
        raw = val.buf
        label = val.label
        val = val.val
        for k, v in pairs(sdiss) do
          subdissect[#subdissect + 1] = v
        end
      else
        sz = size_of(field)

        if sz == nil then
          if reverse then
            error('wssdl: Cannot evaluate the size of the suffix field ' .. utils.quote(field._name))
          elseif #pkt._definition ~= ifield then
            -- Get to the end or the next value field
            local start, iend = find_valued_field_after(ifield)
            if start == -1 then
              return nil, {desegment = DESEGMENT_ONE_MORE_SEGMENT}
            end
            local res, err = dissect_pkt(pkt, start, buf,
                pinfo, iend, ifield + 1, true)

            -- Handle errors
            if err then
              return nil, err
            end

            local len, val, sdiss = unpack(res, 1, 3)
            len = -len

            for k, v in pairs(sdiss) do
              subdissect[#subdissect + 1] = v
            end
            for k, v in pairs(val.sz) do pktval.sz[k] = v end
            for k, v in pairs(val.val) do pktval.val[k] = v end
            for k, v in pairs(val.buf) do pktval.buf[k] = v end
            for k, v in pairs(val.label) do pktval.label[k] = v end

            sz = (start - len) - idx
          else
            sz = buf:len() * 8 - idx
          end
        end

        local offlen = math.ceil((sz + idx % 8) / 8)
        local needed = reverse and math.ceil(idx / 8)
                               or  math.floor(idx / 8) + offlen

        raw = buf(0,0)
        if sz > 0 and needed > buf:len() or needed < offlen then
          if needed < 0 then
            needed = buf:len() - needed
          end
          return nil, {needed = needed}
        end

        if needed <= buf:len() and sz > 0 then
          raw = buf(reverse and math.ceil(idx / 8) - offlen or math.floor(idx / 8), offlen)
        end

        if field._type == 'payload' then
          local dtname = field._dt_name or
              table.concat({string.lower(proto.name),
                            unpack(field._dissection_criterion)}, '.')

          local ok, dt = pcall(DissectorTable.get, dtname)
          if not ok then
            error('wssdl: DissectorTable ' .. utils.quote(dtname) .. ' does not exist.')
          end
          local val = pktval.val
          for i, v in pairs(field._dissection_criterion) do
            val = val[v]
            if not val then
              error('wssdl: Dissection criterion for ' .. utils.quote(field._name) ..
                    ' does not match a real field.')
            end
          end
          subdissect[#subdissect + 1] = {dt = dt, tvb = raw:tvb(), val = val}
        else
          local df = dissect_type[field._type .. '_' .. type(sz)]
                  or dissect_type[field._type .. '_' .. tostring(sz)]
                  or dissect_type[field._type]
                  or dissect_type.default

          raw, val, sz, label = df(field, buf, raw, idx, sz, reverse)
        end
      end

      return {raw, val, sz, label}
    end

    local istep  = reverse and -1 or 1

    for i = istart, iend, istep do
      local field = pkt._definition[i]

      if pktval.val[field._name] == nil then

        local res, err = dissect_field(i, field, idx)
        if err then
          if err.needed and err.needed > 0 then
            if prop_desegment and not err.desegment then
              local desegment = (err.needed - buf:len()) * 8
              for j = i + 1, #pkt._definition do
                local len = #pkt._definition[j]
                if type(len) ~= 'number' then
                  err.desegment = DESEGMENT_ONE_MORE_SEGMENT
                  return nil, err
                end
                desegment = desegment + len
              end
              err.desegment = math.ceil(desegment / 8)
            else
              err.expert = proto.experts.too_short
            end
          end
          return nil, err
        end

        local raw, val, len, label = unpack(res, 1, 4)

        if field._accept or field._reject then
          local ok = false
          for k, v in pairs(field._accept or {}) do
            if v(val) then
              ok = true
              break
            end
          end
          if ok then
            for k, v in pairs(field._reject or {}) do
              if not v(val) then
                ok = false
                break
              end
            end
          end
          if not ok then
            return nil, {reject = true}
          end
        end

        pktval.sz[field._name] = len
        pktval.buf[field._name] = raw
        pktval.val[field._name] = val
        pktval.label[field._name] = label

      end
      idx = reverse and idx - pktval.sz[field._name] or idx + pktval.sz[field._name]
    end

    return {idx - start, pktval, subdissect}
  end

  local function dissect_proto(pkt, buf, pinfo, root)
    local pkt = utils.deepcopy(pkt)

    -- Don't clone the packet definition further when evaluating
    pkt._properties.noclone = true

    local res, err = dissect_pkt(pkt, 0, buf, pinfo, 1, #pkt._definition, false)
    if err and err.desegment then
      return -1, err.desegment
    end

    pinfo.cols.protocol = proto.name
    local tree = root:add(proto, buf(), proto.description)

    if err then
      if err.expert then
        tree:add_proto_expert_info(err.expert)
      end
      if err.reject then
        return 0
      end
      return -1, 0
    end

    local len, val, subdissect = unpack(res, 1, 3)
    tree_add_fields(pkt, string.lower(proto.name) .. '.', tree, val)

    for k, v in pairs(subdissect) do
      if v.tvb:len() > 0 then
        v.dt:try(v.val, v.tvb, pinfo, root)
      end
    end

    return math.ceil(len / 8)
  end

  return function(buf, pinfo, root)
    local pktlen = buf:len()
    local consumed = 0

    if prop_desegment then
      while consumed < pktlen do
        local result, desegment = dissect_proto(pkt, buf(consumed):tvb(), pinfo, root)
        if result > 0 then
          consumed = consumed + result
        elseif result == 0 then
          return 0
        elseif desegment ~= 0 then
          pinfo.desegment_offset = consumed
          pinfo.desegment_len = desegment
          return pktlen
        else
          return
        end
      end
    else
      local result = dissect_proto(pkt, buf, pinfo, root)
      if result < 0 then
        return
      end
      return result
    end
    return consumed
  end
end

ws.proto = function (pkt, name, description)
  local ok, res = pcall(Proto.new, name, description)
  -- Propagate error with the correct stack level
  if not ok then
    error(res, 2)
  end
  local proto = res
  ws.make_fields(proto.fields, pkt, string.lower(name) .. '.')

  proto.experts.too_short = ProtoExpert.new(
      string.lower(name) .. '.too_short.expert',
      name .. ' message too short',
      expert.group.MALFORMED, expert.severity.ERROR)

  for i, field in ipairs(pkt._definition) do
    if field._type == 'payload' then
      local dtname = field._dt_name or
          table.concat({string.lower(proto.name),
                        unpack(field._dissection_criterion)}, '.')

      local criterion = field._dissection_criterion
      local target = pkt
      local j = 1
      for k, v in pairs(criterion) do
        local tfield = target._definition[target._lookup[v]]
        if j < #criterion then
          if tfield._type ~= 'packet' then
            error('wssdl: DissectorTable key ' .. utils.quote(dtname) .. ' does not match a field.', 2)
          end
          target = tfield._packet
        else
          target = tfield
        end
        j = j + 1
      end
      local ok = pcall(DissectorTable.get, dtname)
      if not ok then
        DissectorTable.new(dtname, nil, target._ftype)
      end
    end
  end

  proto.dissector = ws.dissector(pkt, proto)
  return proto
end

return ws
