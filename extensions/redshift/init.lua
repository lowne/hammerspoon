--- === hs.redshift ===
---
--- Inverts and/or lowers the color temperature of the screen(s) on a schedule, for a more pleasant experience at night
---
--- Usage:
--- ```
--- -- make a windowfilterDisable for redshift: VLC, Photos and screensaver/login window will disable color adjustment and inversion
--- local wfRedshift=hs.window.filter.new({VLC={focused=true},Photos={focused=true},loginwindow={visible=true,allowRoles='*'}},'wf-redshift')
--- -- start redshift: 2800K + inverted from 21 to 7, very long transition duration (19->23 and 5->9)
--- hs.redshift.start(2800,'21:00','7:00','4h',true,wfRedshift)
--- -- allow manual control of inverted colors
--- bind(HYPER,'f1','Invert',hs.redshift.toggleInvert)
--- ```

local screen=require'hs.screen'
local timer=require'hs.timer'
local windowfilter=require'hs.window.filter'
local settings=require'hs.settings'
local log=require'hs.logger'.new('redshift')
local redshift={setLogLevel=log.setLogLevel} -- module

local type,ipairs,pairs,next,floor,abs,max,sformat=type,ipairs,pairs,next,math.floor,math.abs,math.max,string.format

local SETTING_INVERTED_OVERRIDE='hs.redshift.inverted.override'
--local BLACKPOINT = {red=0.00000001,green=0.00000001,blue=0.00000001}
local BLACKPOINT = {red=0,green=0,blue=0}
local COLORRAMP

local running,nightStart,nightEnd,dayStart,dayEnd,nightTemp,dayTemp
local tmr,tmrNext,applyGamma,screenWatcher
local invertRequests,invertCallbacks,invertAtNight,invertUser,prevInvert={},{}
local wfDisable,modulewfDisable

local function round(v) return floor(0.5+v) end
local function lerprgb(p,a,b) return {red=a[1]*(1-p)+b[1]*p,green=a[2]*(1-p)+b[2]*p,blue=a[3]*(1-p)+b[3]*p} end
local function ilerp(v,s,e,a,b)
  if s>e then
    if v<e then v=v+86400 end
    e=e+86400
  end
  local p=(v-s)/(e-s)
  return a*(1-p)+b*p
end
local function getGamma(temp)
  local idx=floor(temp/100)-9
  local p=(temp%100)/100
  return lerprgb(p,COLORRAMP[idx],COLORRAMP[idx+1])
end
local function between(v,s,e)
  if s<=e then return v>=s and v<=e else return v>=s or v<=e end
end

-- core fn
applyGamma=function(testtime)
  if tmrNext then tmrNext:stop() tmrNext=nil end
  local now=testtime and timer.seconds(testtime) or timer.localTime()
  local temp,timeNext,invertReq
  if between(now,nightStart,nightEnd) then temp=ilerp(now,nightStart,nightEnd,dayTemp,nightTemp) --dusk
  elseif between(now,dayStart,dayEnd) then temp=ilerp(now,dayStart,dayEnd,nightTemp,dayTemp) --dawn
  elseif between(now,dayEnd,nightStart) then temp=dayTemp timeNext=nightStart log.i('daytime')--day
  elseif between(now,nightEnd,dayStart) then invertReq=invertAtNight temp=nightTemp timeNext=dayStart log.i('nighttime')--night
  else error('wtf') end
  redshift.requestInvert('redshift-night',invertReq)
  local invert=redshift.isInverted()
  local gamma=getGamma(temp)
  log.df('set color temperature %dK (gamma %d,%d,%d)%s',floor(temp),round(gamma.red*100),
    round(gamma.green*100),round(gamma.blue*100),invert and (' - inverted by '..invert) or '')
  for _,scr in ipairs(screen.allScreens()) do
    scr:setGamma(invert and BLACKPOINT or gamma,invert and gamma or BLACKPOINT)
  end
  if invert~=prevInvert then
    log.f('inverted status changed%s',next(invertCallbacks) and ', notifying callbacks' or '')
    for _,fn in pairs(invertCallbacks) do fn(invert) end
    prevInvert=invert
  end
  if timeNext then
    tmrNext=timer.doAt(timeNext,applyGamma)
  else
    tmr:start()
  end
end

--- hs.redshift.invertSubscribe([id,]fn)
--- Function
--- Subscribes a callback to be notified when the color inversion status changes
---
--- You can use this to dynamically adjust the UI colors in your modules or configuration, if appropriate.
---
--- Parameters:
---  * id - (optional) a string identifying the requester (usually the module name); if omitted, `fn`
---    itself will be the identifier; this identifier must be passed to `hs.redshift.invertUnsubscribe()`
---  * fn - a function that will be called whenever color inversion status changes; it must accept a
---    single parameter, a string or false as per the return value of `hs.redshift.isInverted()`
---
--- Returns:
---  * None
function redshift.invertSubscribe(key,fn)
  if type(key)=='function' then fn=key end
  if type(key)~='string' and type(key)~='function' then error('invalid key',2) end
  if type(fn)~='function' then error('invalid callback',2) end
  invertCallbacks[key]=fn
  log.f('add invert callback %s',key)
  return running and fn(redshift.isInverted())
end
--- hs.redshift.invertUnsubscribe(id)
--- Function
--- Unsubscribes a previously subscribed color inversion change callback
---
--- Parameters:
---  * id - a string identifying the requester or the callback function itself, depending on how you
---    called `hs.redshift.invertSubscribe()`
---
--- Returns:
---  * None
function redshift.invertUnsubscribe(key)
  if not invertCallbacks[key] then return end
  log.f('remove invert callback %s',key)
  invertCallbacks[key]=nil
end

--- hs.redshift.isInverted() -> string or false
--- Function
--- Checks if the colors are currently inverted
---
--- Parameters:
---  * None
---
--- Returns:
---  * false if the colors are not currently inverted; otherwise, a string indicating the reason, one of:
---    * "user" for the user override (see `hs.redshift.toggleInvert()`)
---    * "redshift-night" if `hs.redshift.start()` was called with `invertAtNight` set to true,
---      and it's currently night time
---    * the ID string (usually the module name) provided to `hs.redshift.requestInvert()`, if another module requested color inversion
local function isInverted()
  if not running then return false end
  if invertUser~=nil then return invertUser and 'user'
  else return next(invertRequests) or false end
end
redshift.isInverted=isInverted

--- hs.redshift.requestInvert(id,v)
--- Function
--- Sets or clears a request for color inversion
---
--- Parameters:
---  * id - a string identifying the requester (usually the module name)
---  * v - a boolean indicating whether to invert the colors (if true) or clear any previous requests (if false or nil)
---
--- Returns:
---  * None
---
--- Notes:
---  * you can use this function e.g. to automatically invert colors if the ambient light sensor reading drops below
---    a certain threshold (`hs.brightness.DDCauto()` can optionally do exactly that)
---  * if the user's configuration doesn't explicitly start the redshift module, calling this will have no effect
function redshift.requestInvert(key,v)
  if type(key)~='string' then error('key must be a string',2) end
  if v==false then v=nil end
  if invertRequests[key]==v then return end
  invertRequests[key]=v
  log.f('invert request from %s %s',key,v and '' or 'canceled')
  return running and applyGamma()
end

--- hs.redshift.toggleInvert([v])
--- Function
--- Sets or clears the user override for color inversion.
---
--- This function should be bound to a hotkey, e.g.:
--- `hs.hotkey.bind('ctrl-cmd','=','Invert',hs.redshift.toggleInvert)`
---
--- Parameters:
---  * v - (optional) a boolean; if true, the override will invert the colors no matter what; if false,
---    the override will disable color inversion no matter what; if omitted or nil, it will toggle the
---    override, i.e. clear it if it's currently enforced, or set it to the opposite of the current
---    color inversion status otherwise.
---
--- Returns:
---  * None
function redshift.toggleInvert(v)
  if not running then return end
  if v==nil and invertUser==nil then v=not isInverted() end
  if v~=nil and type(v)~='boolean' then error ('v must be a boolean or nil',2) end
  log.f('invert user override%s',v==true and ': inverted' or (v==false and ': not inverted' or ' cancelled'))
  if v==nil then settings.clear(SETTING_INVERTED_OVERRIDE)
  else settings.set(SETTING_INVERTED_OVERRIDE,v) end
  invertUser=v
  return applyGamma()
end

local function pause()
  log.i('paused')
  screen.restoreGamma()
  tmr:stop()
end
local function resume()
  log.i('resumed')
  return applyGamma()
end

--- hs.redshift.stop()
--- Function
--- Stops the module and disables color adjustment and color inversion
---
--- Parameters:
---  * None
---
--- Returns:
---  * None
function redshift.stop()
  if not running then return end
  pause()
  if wfDisable then
    if modulewfDisable then modulewfDisable:delete() modulewfDisable=nil
    else wfDisable:unsubscribe({pause,resume}) end
    wfDisable=nil
  end
  if tmrNext then tmrNext:stop() tmrNext=nil end
  screenWatcher:stop() screenWatcher=nil
  running=nil
end

local function stime(time)
  return sformat('%02d:%02d:%02d',floor(time/3600),floor(time/60)%60,floor(time%60))
end

tmr=timer.delayed.new(10,applyGamma)
--- hs.redshift.start(colorTemp,nightStart,nightEnd[,transition[,invertAtNight[,windowfilterDisable[,dayColorTemp]]]])
--- Function
--- Sets the schedule and (re)starts the module
---
--- Parameters:
---  * colorTemp - a number indicating the desired color temperature (Kelvin) during the night cycle;
---    the recommended range is between 3600K and 1400K; lower values (minimum 1000K) result in a more pronounced adjustment
---  * nightStart - a string in the format "HH:MM" (24-hour clock) or number of seconds after midnight
---    (see `hs.timer.seconds()`) indicating when the night cycle should start
---  * nightEnd - a string in the format "HH:MM" (24-hour clock) or number of seconds after midnight
---    (see `hs.timer.seconds()`) indicating when the night cycle should end
---  * transition - (optional) a string or number of seconds (see `hs.timer.seconds()`) indicating the duration of
---    the transition to the night color temperature and back; if omitted, defaults to 1 hour
---  * invertAtNight - (optional) a boolean indicating whether the colors should be inverted (in addition to
---    the color temperature shift) during the night; if omitted, defaults to false
---  * windowfilterDisable - (optional) an `hs.window.filter` instance that will disable color adjustment
---    (and color inversion) whenever any window is allowed; alternatively, you can just provide a list of application
---    names (typically media apps and/or apps for color-sensitive work) and a windowfilter will be created
---    for you that disables color adjustment whenever one of these apps is focused
---  * dayColorTemp - (optional) a number indicating the desired color temperature (in Kelvin) during the day cycle;
---    you can use this to maintain some degree of "redshift" during the day as well, or, if desired, you can
---    specify a value higher than 6500K (up to 10000K) for more bluish colors, although that's not recommended;
---    if omitted, defaults to 6500K, which disables color adjustment and restores your screens' original color profiles
---
--- Returns:
---  * None
function redshift.start(nTemp,nStart,nEnd,dur,invert,wf,dTemp)
  if not dTemp then dTemp=6500 end
  if nTemp<1000 or nTemp>10000 or dTemp<1000 or dTemp>10000 then error('invalid color temperature',2) end
  nStart,nEnd=timer.seconds(nStart),timer.seconds(nEnd)
  dur=timer.seconds(dur or 3600)
  if dur>14400 then error('max transition time is 4h',2) end
  if abs(nStart-nEnd)<dur or abs(nStart-nEnd+86400)<dur
    or abs(nStart-nEnd-86400)<dur then error('nightTime too close to dayTime',2) end
  nightTemp,dayTemp=floor(nTemp),floor(dTemp)
  redshift.stop()

  invertAtNight=invert
  nightStart,nightEnd=(nStart-dur/2)%86400,(nStart+dur/2)%86400
  dayStart,dayEnd=(nEnd-dur/2)%86400,(nEnd+dur/2)%86400
  log.f('started: %dK @ %s -> %dK @ %s,%s %dK @ %s -> %dK @ %s',
    dayTemp,stime(nightStart),nightTemp,stime(nightEnd),invert and ' inverted,' or '',nightTemp,stime(dayStart),dayTemp,stime(dayEnd))
  running=true
  tmr:setDelay(max(1,dur/200))
  screenWatcher=screen.watcher.new(function()tmr:start(5)end):start()
  invertUser=settings.get(SETTING_INVERTED_OVERRIDE)
  applyGamma()
  if wf~=nil then
    if windowfilter.iswf(wf) then wfDisable=wf
    else
      wfDisable=windowfilter.new(wf,'wf-redshift',log.getLogLevel())
      modulewfDisable=wfDisable
      if type(wf=='table') then
        local isAppList=true
        for k,v in pairs(wf) do
          if type(k)~='number' or type(v)~='string' then isAppList=false break end
        end
        if isAppList then wfDisable:setOverrideFilter{focused=true} end
      end
    end
    wfDisable:subscribe(windowfilter.hasWindow,pause,true):subscribe(windowfilter.hasNoWindows,resume)
  end
end

COLORRAMP={ -- from https://github.com/jonls/redshift/blob/master/src/colorramp.c
  {1.00000000,  0.18172716,  0.00000000}, -- 1000K
  {1.00000000,  0.25503671,  0.00000000}, -- 1100K
  {1.00000000,  0.30942099,  0.00000000}, -- 1200K
  {1.00000000,  0.35357379,  0.00000000}, -- ...
  {1.00000000,  0.39091524,  0.00000000},
  {1.00000000,  0.42322816,  0.00000000},
  {1.00000000,  0.45159884,  0.00000000},
  {1.00000000,  0.47675916,  0.00000000},
  {1.00000000,  0.49923747,  0.00000000},
  {1.00000000,  0.51943421,  0.00000000},
  {1.00000000,  0.54360078,  0.08679949},
  {1.00000000,  0.56618736,  0.14065513},
  {1.00000000,  0.58734976,  0.18362641},
  {1.00000000,  0.60724493,  0.22137978},
  {1.00000000,  0.62600248,  0.25591950},
  {1.00000000,  0.64373109,  0.28819679},
  {1.00000000,  0.66052319,  0.31873863},
  {1.00000000,  0.67645822,  0.34786758},
  {1.00000000,  0.69160518,  0.37579588},
  {1.00000000,  0.70602449,  0.40267128},
  {1.00000000,  0.71976951,  0.42860152},
  {1.00000000,  0.73288760,  0.45366838},
  {1.00000000,  0.74542112,  0.47793608},
  {1.00000000,  0.75740814,  0.50145662},
  {1.00000000,  0.76888303,  0.52427322},
  {1.00000000,  0.77987699,  0.54642268},
  {1.00000000,  0.79041843,  0.56793692},
  {1.00000000,  0.80053332,  0.58884417},
  {1.00000000,  0.81024551,  0.60916971},
  {1.00000000,  0.81957693,  0.62893653},
  {1.00000000,  0.82854786,  0.64816570},
  {1.00000000,  0.83717703,  0.66687674},
  {1.00000000,  0.84548188,  0.68508786},
  {1.00000000,  0.85347859,  0.70281616},
  {1.00000000,  0.86118227,  0.72007777},
  {1.00000000,  0.86860704,  0.73688797},
  {1.00000000,  0.87576611,  0.75326132},
  {1.00000000,  0.88267187,  0.76921169},
  {1.00000000,  0.88933596,  0.78475236},
  {1.00000000,  0.89576933,  0.79989606},
  {1.00000000,  0.90198230,  0.81465502},
  {1.00000000,  0.90963069,  0.82838210},
  {1.00000000,  0.91710889,  0.84190889},
  {1.00000000,  0.92441842,  0.85523742},
  {1.00000000,  0.93156127,  0.86836903},
  {1.00000000,  0.93853986,  0.88130458},
  {1.00000000,  0.94535695,  0.89404470},
  {1.00000000,  0.95201559,  0.90658983},
  {1.00000000,  0.95851906,  0.91894041},
  {1.00000000,  0.96487079,  0.93109690},
  {1.00000000,  0.97107439,  0.94305985},
  {1.00000000,  0.97713351,  0.95482993},
  {1.00000000,  0.98305189,  0.96640795},
  {1.00000000,  0.98883326,  0.97779486},
  {1.00000000,  0.99448139,  0.98899179},
  {1.00000000,  1.00000000,  1.00000000}, -- 6500K
  --  {0.99999997,  0.99999997,  0.99999997}, --6500K
  {0.98947904,  0.99348723,  1.00000000},
  {0.97940448,  0.98722715,  1.00000000},
  {0.96975025,  0.98120637,  1.00000000},
  {0.96049223,  0.97541240,  1.00000000},
  {0.95160805,  0.96983355,  1.00000000},
  {0.94303638,  0.96443333,  1.00000000},
  {0.93480451,  0.95923080,  1.00000000},
  {0.92689056,  0.95421394,  1.00000000},
  {0.91927697,  0.94937330,  1.00000000},
  {0.91194747,  0.94470005,  1.00000000},
  {0.90488690,  0.94018594,  1.00000000},
  {0.89808115,  0.93582323,  1.00000000},
  {0.89151710,  0.93160469,  1.00000000},
  {0.88518247,  0.92752354,  1.00000000},
  {0.87906581,  0.92357340,  1.00000000},
  {0.87315640,  0.91974827,  1.00000000},
  {0.86744421,  0.91604254,  1.00000000},
  {0.86191983,  0.91245088,  1.00000000},
  {0.85657444,  0.90896831,  1.00000000},
  {0.85139976,  0.90559011,  1.00000000},
  {0.84638799,  0.90231183,  1.00000000},
  {0.84153180,  0.89912926,  1.00000000},
  {0.83682430,  0.89603843,  1.00000000},
  {0.83225897,  0.89303558,  1.00000000},
  {0.82782969,  0.89011714,  1.00000000},
  {0.82353066,  0.88727974,  1.00000000},
  {0.81935641,  0.88452017,  1.00000000},
  {0.81530175,  0.88183541,  1.00000000},
  {0.81136180,  0.87922257,  1.00000000},
  {0.80753191,  0.87667891,  1.00000000},
  {0.80380769,  0.87420182,  1.00000000},
  {0.80018497,  0.87178882,  1.00000000},
  {0.79665980,  0.86943756,  1.00000000},
  {0.79322843,  0.86714579,  1.00000000},
  {0.78988728,  0.86491137,  1.00000000}, -- 10000K
  {0.78663296,  0.86273225,  1.00000000},
}
return redshift
