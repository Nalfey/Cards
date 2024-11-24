--[[
Copyright © 2013-2015, Giuliano Riccio
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

* Redistributions of source code must retain the above copyright
notice, this list of conditions and the following disclaimer.
* Redistributions in binary form must reproduce the above copyright
notice, this list of conditions and the following disclaimer in the
documentation and/or other materials provided with the distribution.
* Neither the name of Cards nor the
names of its contributors may be used to endorse or promote products
derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL Giuliano Riccio BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
]]

_addon.name    = 'Cards'
_addon.author  = 'Nalfey'
_addon.version = '1.10'
_addon.commands = {'cards'}

require('chat')
require('lists')
require('logger')
require('sets')
require('tables')
require('strings')
require('pack')

file  = require('files')
slips = require('slips')
config = require('config')
texts = require('texts')
res = require('resources')

-- Add this near the top of the file with your other requires
job_equipment = require('job_equipment')

defaults = {}
defaults.Track = ''
defaults.Tracker = {}
defaults.KeyItemDisplay = true

settings = config.load(defaults)

tracker = texts.new(settings.Track, settings.Tracker, settings)

do
    config.register(settings, function(settings)
        tracker:text(settings.Track)
        tracker:visible(settings.Track ~= '' and windower.ffxi.get_info().logged_in)
    end)

    local bag_ids = res.bags:rekey('english'):key_map(string.lower):map(table.get-{'id'})

    local variable_cache = S{}
    tracker:register_event('reload', function()
        for variable in tracker:it() do
            local bag_name, search = variable:match('(.*):(.*)')

            local bag = bag_name == 'all' and 'all' or bag_ids[bag_name:lower()]
            if not bag and bag_name ~= 'all' then
                warning('Unknown bag: %s':format(bag_name))
            else
                if not S{'$freespace', '$usedspace', '$maxspace'}:contains(search:lower()) then
                    local items = S(res.items:name(windower.wc_match-{search})) + S(res.items:name_log(windower.wc_match-{search}))
                    if items:empty() then
                        warning('No items matching "%s" found.':format(search))
                    else
                        variable_cache:add({
                            name = variable,
                            bag = bag,
                            type = 'item',
                            ids = items:map(table.get-{'id'}),
                            search = search,
                        })
                    end
                else
                    variable_cache:add({
                        name = variable,
                        bag = bag,
                        type = 'info',
                        search = search,
                    })
                end
            end
        end
    end)

    do
        local update = T{}

        local search_bag = function(bag, ids)
            return bag:filter(function(item)
                return type(item) == 'table' and ids:contains(item.id)
            end):reduce(function(acc, item)
                return type(item) == 'table' and item.count + acc or acc
            end, 0)
        end

        local last_check = 0

        windower.register_event('prerender', function()
            if os.clock() - last_check < 0.25 then
                return
            end
            last_check = os.clock()

            local items = T{}
            for variable in variable_cache:it() do
                if variable.type == 'info' then
                    local info
                    if variable.bag == 'all' then
                        info = {
                            max = 0,
                            count = 0
                        }
                        for bag_info in T(windower.ffxi.get_bag_info()):it() do
                            info.max = info.max + bag_info.max
                            info.count = info.count + bag_info.count
                        end
                    else
                        info = windower.ffxi.get_bag_info(variable.bag)
                    end

                    update[variable.name] =
                        variable.search == '$freespace' and (info.max - info.count)
                        or variable.search == '$usedspace' and info.count
                        or variable.search == '$maxspace' and info.max
                        or nil
                elseif variable.type == 'item' then
                    if variable.bag == 'all' then
                        for id in bag_ids:it() do
                            if not items[id] then
                                items[id] = T(windower.ffxi.get_items(id))
                            end
                        end
                    else
                        if not items[variable.bag] then
                            items[variable.bag] = T(windower.ffxi.get_items(variable.bag))
                        end
                    end

                    update[variable.name] = variable.bag ~= 'all' and search_bag(items[variable.bag], variable.ids) or items:reduce(function(acc, bag)
                        return acc + search_bag(bag, variable.ids)
                    end, 0)
                end
            end

            if not update:empty() then
                tracker:update(update)
            end
        end)
    end
end

zone_search            = windower.ffxi.get_info().logged_in
first_pass             = true
item_names             = T{}
key_item_names         = T{}
global_storages        = T{}
storages_path          = windower.addon_path..'data\\'
storages_order_tokens  = L{'temporary', 'inventory', 'wardrobe', 'wardrobe 2', 'wardrobe 3', 'wardrobe 4', 'wardrobe 5', 'wardrobe 6', 'wardrobe 7', 'wardrobe 8', 'safe', 'safe 2', 'storage', 'locker', 'satchel', 'sack', 'case'}
storages_order         = S(res.bags:map(string.gsub-{' ', ''} .. string.lower .. table.get-{'english'})):sort(function(name1, name2)
    local index1 = storages_order_tokens:find(name1)
    local index2 = storages_order_tokens:find(name2)

    if not index1 and not index2 then
        return name1 < name2
    end

    if not index1 then
        return false
    end

    if not index2 then
        return true
    end

    return index1 < index2
end)
local storage_slips_order = slips.storages:map(function(id)
    return 'slip ' .. res.items[id].english:lower():match('^storage slip (.*)$')
end)
merged_storages_orders = storages_order + storage_slips_order + L{'key items'}

function get_local_storage()
    local items = windower.ffxi.get_items()
    if not items then
        error('Failed to get items from FFXI')
        return false
    end

    local storages = {
        gil = type(items.gil) == 'number' and items.gil or 0
    }

    for _, storage_name in ipairs(storages_order) do
        storages[storage_name] = T{}

        for _, data in ipairs(items[storage_name]) do
            if type(data) == 'table' then
				if data.id ~= 0 then
					local id = tostring(data.id)
					storages[storage_name][id] = (storages[storage_name][id] or 0) + data.count
				end
			end
        end
    end

    local slip_storages = slips.get_player_items()

    for _, slip_id in ipairs(slips.storages) do
        local slip_name     = 'slip '..tostring(slips.get_slip_number_by_id(slip_id)):lpad('0', 2)
        storages[slip_name] = T{}

        for _, id in ipairs(slip_storages[slip_id]) do
            storages[slip_name][tostring(id)] = 1
        end
    end
    
    local key_items= windower.ffxi.get_key_items()
    
    storages['key items'] = T{}
    
    for _, id in ipairs(key_items) do
        storages['key items'][tostring(id)] = 1
    end

    return storages
end

function encase_key(key)
    if type(key) == 'number' then
        return '['..tostring(key)..']'
    elseif type(key) == 'string' then
        return '["'..key..'"]'
    else
        return tostring(key)
    end
end

function make_table(tab,tab_offset)
    local offset = " ":rep(tab_offset)
    local ret = "{\n"
    for i,v in pairs(tab) do
        ret = ret..offset..encase_key(i)..' = '
        if type(v) == 'table' then
            ret = ret..make_table(v,tab_offset+2)..',\n'
        else
            ret = ret..tostring(v)..',\n'
        end
    end
    return ret..offset..'}'
end

function update()
    if not windower.ffxi.get_info().logged_in then
        error('You have to be logged in to use this addon.')
        return false
    end

    if zone_search == false then
        notice('Cards has not detected a fully loaded inventory yet.')
        return false
    end

    local player_name = windower.ffxi.get_player().name
    local local_storage = get_local_storage()
    if not local_storage then
        return false
    end

    global_storages[player_name] = local_storage

    if not windower.dir_exists(windower.addon_path..'data') then
        windower.create_dir(windower.addon_path..'data')
    end
    
    local success, err = pcall(function()
        local file = io.open(windower.addon_path..'data\\'..player_name..'.lua', 'w')
        if file then
            file:write('return '..make_table(local_storage,0)..'\n')
            file:close()
        else
            error('Could not open storage file for writing')
        end
    end)
    
    if not success then
        error('Failed to write storage file: ' .. err)
        return false
    end

    collectgarbage()
    return true
end

function update_global_storage()
    local player_name = windower.ffxi.get_player().name
    
    global_storages = T{} 
    
    -- Include current character's storage first
    global_storages[player_name] = get_local_storage()
    
    -- Then add other characters
    for _, f in pairs(windower.get_dir(storages_path)) do
        if f:sub(-4) == '.lua' and f:sub(1,-5) ~= player_name then
            local success, result = pcall(dofile, storages_path .. f)
            if success then
                global_storages[f:sub(1,-5)] = result
            end
        end
    end
end

windower.register_event('incoming chunk', function(id,original,modified,injected,blocked)
    local seq = original:unpack('H',3)
	if (next_sequence and seq == next_sequence) and zone_search then
		update()
        next_sequence = nil
	end

	if id == 0x00B then 
        zone_search = false
    elseif id == 0x00A then 
		zone_search = false
	elseif id == 0x01D and not zone_search then
        zone_search = true
		next_sequence = (seq+22)%0x10000 
    elseif (id == 0x1E or id == 0x1F or id == 0x20) and zone_search then

        next_sequence = (seq+22)%0x10000
	end
end)


windower.register_event('ipc message', function(str)
    if str == 'cards update' then
        update()
    end
end)


handle_command = function(...)
    local params = L{...}
    if not params[1] then
        log('Usage: //cards JOB')
        return
    end
    local job = params[1]:upper()
    find_cards(job)
end

windower.register_event('unhandled command', function(command, ...)
    if command:lower() == 'cards' then
        local args = T{...}
        if not args[1] then
            log('Usage: //cards JOB')
            return
        end
        local job = args[1]:upper()
        find_cards(job)
    elseif command:lower() == 'cardsall' then
        local args = T{...}
        if not args[1] then
            log('Usage: //cardsall JOB')
            return
        end
        local job = args[1]:upper()
        find_cards_all(job)
    elseif command:lower() == 'cardsmats' then
        local args = T{...}
        if not args[1] then
            log('Usage: //cardsmats JOB')
            return
        end
        local job = args[1]:upper()
        check_cards_materials(job)
    end
end)

windower.register_event('addon command', handle_command)


function check_cards_materials(job)
    if not job_equipment[job] then
        log('No equipment data found for job: ' .. job)
        return
    end

    -- Ensure we're logged in and storage is up to date
    if not windower.ffxi.get_info().logged_in then
        error('You have to be logged in to use this command.')
        return
    end

    if not update() then
        error('Failed to update storage information.')
        return
    end

    log('Checking ' .. job .. ' upgrade materials...')
    
    for _, equip_data in ipairs(job_equipment[job]) do
        local equip_names = equip_data[1]
        local base_name = equip_names[1]:gsub(' %+1$', '')
        local materials = equip_data[3]
        
        if materials then
            -- Check current upgrade level
            local found_plus3 = false
            local found_plus2 = false
            local found_plus1 = false
            
            for storage_name, items in pairs(global_storages[windower.ffxi.get_player().name]) do
                if storage_name ~= 'gil' and storage_name ~= 'key items' then
                    for item_id, quantity in pairs(items) do
                        local item = res.items[tonumber(item_id)]
                        if item and item.name then
                            for _, name in ipairs(equip_names) do
                                if name then
                                    local plus3_name = name:gsub(' %+1$', ' +3')
                                    local plus2_name = name:gsub(' %+1$', ' +2')
                                    
                                    if item.name == plus3_name then
                                        found_plus3 = true
                                    elseif item.name == plus2_name then
                                        found_plus2 = true
                                    elseif item.name == name then
                                        found_plus1 = true
                                    end
                                end
                            end
                        end
                    end
                end
            end

            -- Only show relevant upgrade materials
            if found_plus3 then
                -- Already at +3, nothing to show
                log((base_name):color(200) .. ' is already +3')
            elseif found_plus2 then
                -- Show only +3 requirements
                if materials["+3"] then
                    log((base_name .. ' +3'):color(200) .. ' requires: ')
                    local mat_strings = {}
                    for _, mat in ipairs(materials["+3"]) do
                        local count = 0
                        for storage_name, items in pairs(global_storages[windower.ffxi.get_player().name]) do
                            if storage_name ~= 'gil' and storage_name ~= 'key items' then
                                for item_id, quantity in pairs(items) do
                                    local item = res.items[tonumber(item_id)]
                                    if item and item.name == mat.name then
                                        count = count + quantity
                                    end
                                end
                            end
                        end
                        local color = count >= mat.count and 200 or 167
                        local count_str = count >= mat.count 
                            and tostring(count):color(200)  -- Color the count yellow when sufficient
                            or tostring(count)
                        table.insert(mat_strings, mat.name .. ': ' .. count_str .. '/' .. tostring(mat.count):color(color))
                    end
                    log(table.concat(mat_strings, ', '))
                end
            elseif found_plus1 then
                -- Show only +2 requirements
                if materials["+2"] then
                    log((base_name .. ' +2'):color(200) .. ' requires: ')
                    local mat_strings = {}
                    for _, mat in ipairs(materials["+2"]) do
                        local count = 0
                        for storage_name, items in pairs(global_storages[windower.ffxi.get_player().name]) do
                            if storage_name ~= 'gil' and storage_name ~= 'key items' then
                                for item_id, quantity in pairs(items) do
                                    local item = res.items[tonumber(item_id)]
                                    if item and item.name == mat.name then
                                        count = count + quantity
                                    end
                                end
                            end
                        end
                        local color = count >= mat.count and 200 or 167
                        local count_str = count >= mat.count 
                            and tostring(count):color(200)  -- Color the count yellow when sufficient
                            or tostring(count)
                        table.insert(mat_strings, mat.name .. ': ' .. count_str .. '/' .. tostring(mat.count):color(color))
                    end
                    log(table.concat(mat_strings, ', '))
                end
            else
                log((base_name):color(200) .. ' +1 not found yet')
            end
        end
    end
end

function find_cards(job)
    if not job_equipment[job] then
        log('No equipment data found for job: ' .. job)
        return
    end

    -- Ensure we're logged in and storage is up to date
    if not windower.ffxi.get_info().logged_in then
        error('You have to be logged in to use this command.')
        return
    end

    if not update() then
        error('Failed to update storage information.')
        return
    end

    local total_cards = 0
    local card_name = 'P. ' .. job .. ' Card'
    local player_name = windower.ffxi.get_player().name
    
    log('Checking ' .. job .. ' equipment...')
    
    -- Get fresh storage data
    local local_storage = get_local_storage()
    
    -- Count cards (simplified method)
    local existing_cards = 0
    for storage_name, items in pairs(local_storage) do
        if storage_name ~= 'gil' and storage_name ~= 'key items' then
            for item_id, quantity in pairs(items) do
                local item = res.items[tonumber(item_id)]
                if item and item.name == card_name then
                    existing_cards = existing_cards + quantity
                end
            end
        end
    end
    
    -- Check equipment
    for index, equip_data in ipairs(job_equipment[job]) do
        local equip_names = equip_data[1]
        local cards_needed = equip_data[2]
        local base_name = equip_names[1]:gsub(' %+1$', '')
        local found_plus3 = false
        local found_plus2 = false
        local found_plus1 = false
        local found_nq = false
        
        for storage_name, items in pairs(local_storage) do
            if storage_name ~= 'gil' and storage_name ~= 'key items' then
                for item_id, quantity in pairs(items) do
                    local item = res.items[tonumber(item_id)]
                    if item and item.name then
                        for _, name in ipairs(equip_names) do
                            if name then
                                local nq_name = name:gsub(' %+1$', '')
                                local plus3_name = name:gsub(' %+1$', ' +3')
                                local plus2_name = name:gsub(' %+1$', ' +2')
                                
                                if item.name == plus3_name then
                                    found_plus3 = true
                                    log(base_name:color(255) .. ': ' .. 'Already +3':color(158))
                                    break
                                elseif item.name == plus2_name then
                                    found_plus2 = true
                                elseif item.name == name then
                                    found_plus1 = true
                                elseif item.name == nq_name then
                                    found_nq = true
                                end
                            end
                        end
                    end
                    if found_plus3 then break end
                end
            end
            if found_plus3 then break end
        end
        
        if not found_plus3 then
            if found_plus2 then
                local plus2_cards
                if index == 1 then plus2_cards = 40
                elseif index == 2 then plus2_cards = 50
                elseif index == 3 then plus2_cards = 35
                elseif index == 4 then plus2_cards = 45
                elseif index == 5 then plus2_cards = 30 end
                total_cards = total_cards + plus2_cards
                log(base_name:color(255) .. ': Needs ' .. tostring(plus2_cards):color(158) .. ' cards ' .. '(currently +2)':color(158))
            elseif found_plus1 then
                total_cards = total_cards + cards_needed
                log(base_name:color(255) .. ': Needs ' .. tostring(cards_needed):color(158) .. ' cards ' .. '(currently +1)':color(158))
            elseif found_nq then
                total_cards = total_cards + cards_needed
                log(base_name:color(255) .. ': Needs ' .. tostring(cards_needed):color(158) .. ' cards ' .. '(currently NQ)':color(158))
            else
                log(base_name:color(255) .. ': ' .. 'Not found':color(158))
            end
        end
    end
    
    if total_cards > 0 then
        log('Total ' .. card_name .. 's needed: ' .. tostring(total_cards):color(158))
        log('You currently have: ' .. tostring(existing_cards):color(158) .. ' cards')
        local remaining_cards = total_cards - existing_cards
        if remaining_cards > 0 then
            log('Additional cards needed: ' .. tostring(remaining_cards):color(158))
        end
    else
        log('No upgrades needed')
        log('You currently have: ' .. tostring(existing_cards):color(158) .. ' cards')
    end
end

windower.register_event('load', function()
    if windower.ffxi.get_info().logged_in then
        update()
    end
end)

windower.register_event('login', function()
    update()
end)


function find_cards_all(job)
    if not job_equipment[job] then
        log('No equipment data found for job: ' .. job)
        return
    end

    -- First, check equipment on current character
    if not windower.ffxi.get_info().logged_in then
        error('You have to be logged in to use this command.')
        return
    end

    if not update() then
        error('Failed to update storage information.')
        return
    end

    local total_cards = 0
    local card_name = 'P. ' .. job .. ' Card'
    local player_name = windower.ffxi.get_player().name
    
    log('Checking ' .. job .. ' equipment...')
    
    -- Check equipment for current character
    for index, equip_data in ipairs(job_equipment[job]) do
        local equip_names = equip_data[1]
        local cards_needed = equip_data[2]
        local base_name = equip_names[1]:gsub(' %+1$', '')
        local found_plus3 = false
        local found_plus2 = false
        local found_plus1 = false
        local found_nq = false
        
        local storages = global_storages[player_name]
        if storages then
            for storage_name, items in pairs(storages) do
                if storage_name ~= 'gil' and storage_name ~= 'key items' then
                    for item_id, quantity in pairs(items) do
                        local item = res.items[tonumber(item_id)]
                        if item and item.name then
                            for _, name in ipairs(equip_names) do
                                if name then
                                    local nq_name = name:gsub(' %+1$', '')
                                    local plus3_name = name:gsub(' %+1$', ' +3')
                                    local plus2_name = name:gsub(' %+1$', ' +2')
                                    
                                    if item.name == plus3_name then
                                        found_plus3 = true
                                        log(base_name:color(255) .. ': ' .. 'Already +3':color(158))
                                        break
                                    elseif item.name == plus2_name then
                                        found_plus2 = true
                                    elseif item.name == name then
                                        found_plus1 = true
                                    elseif item.name == nq_name then
                                        found_nq = true
                                    end
                                end
                            end
                        end
                        if found_plus3 then break end
                    end
                end
                if found_plus3 then break end
            end
        end
        
        if not found_plus3 then
            if found_plus2 then
                local plus2_cards
                if index == 1 then plus2_cards = 40
                elseif index == 2 then plus2_cards = 50
                elseif index == 3 then plus2_cards = 35
                elseif index == 4 then plus2_cards = 45
                elseif index == 5 then plus2_cards = 30 end
                total_cards = total_cards + plus2_cards
                log(base_name:color(255) .. ': Needs ' .. tostring(plus2_cards):color(158) .. ' cards ' .. '(currently +2)':color(158))
            elseif found_plus1 then
                total_cards = total_cards + cards_needed
                log(base_name:color(255) .. ': Needs ' .. tostring(cards_needed):color(158) .. ' cards ' .. '(currently +1)':color(158))
            elseif found_nq then
                total_cards = total_cards + cards_needed
                log(base_name:color(255) .. ': Needs ' .. tostring(cards_needed):color(158) .. ' cards ' .. '(currently NQ)':color(158))
            else
                log(base_name:color(255) .. ': ' .. 'Not found':color(158))
            end
        end
    end

    -- Check all characters for cards
    update_global_storage()
    local total_available_cards = 0
    local cards_by_char = {}
    
    for char_name, storage in pairs(global_storages) do
        local char_cards = 0
        for storage_name, items in pairs(storage) do
            if storage_name ~= 'gil' and storage_name ~= 'key items' then
                for item_id, quantity in pairs(items) do
                    local item = res.items[tonumber(item_id)]
                    if item and item.name == card_name then
                        char_cards = char_cards + quantity
                    end
                end
            end
        end
        if char_cards > 0 then
            cards_by_char[char_name] = char_cards
            total_available_cards = total_available_cards + char_cards
        end
    end

    -- Display results
    log('Total ' .. card_name .. 's needed: ' .. tostring(total_cards):color(158))
    log('Available cards by character:')
    for char_name, count in pairs(cards_by_char) do
        log('  ' .. char_name .. ': ' .. tostring(count):color(158))
    end  -- This end was missing
    log('Total available cards: ' .. tostring(total_available_cards):color(158))
    
    local remaining_cards = total_cards - total_available_cards
    if remaining_cards > 0 then
        log('Additional cards needed: ' .. tostring(remaining_cards):color(158))
    end
end

