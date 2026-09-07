# Internal contract for bundled Lua modules

All `src/*.lua` modules return `function(B) ... end`. The builder invokes them
with one shared B table, in explicit order; no runtime filesystem/require.
Modules must never issue orders except through executor.lua.

support.lua supplies additional candidates through B.support.candidates(s).
Executor calls B.support.issued(s,intent) only after an accepted order; intent
flags trade/gank/wardSpot drive bounded disengagement and attempt cooldowns.
Reset this state on game reset or Bot toggle, not on every mode transition.

Pure math helpers: B.dist(a,b), B.add(a,b), B.sub(a,b), B.scale(v,k),
B.norm(v), B.toward(a,b,d), B.clamp(n,lo,hi), B.has(unit,modifier),
B.near(list,pos,radius), B.find(list,index). Positions are plain {x,y,z}.
B.call(tableName,method,fallback,...) safely invokes an Umbrella function.
B.log(key,message,interval) deduplicates diagnostics. B.config has laningEnd=600.

State s: now=game elapsed clock, time=DOTA clock, hero, player (handle),
role=4/5, lane='top'/'mid'/'bot', allies (excludes self), enemies (visible only),
creeps (both teams), neutrals, towers, structures, wards, objectives, runes,
camps, trees, projectiles, byIndex, abilities (name->ability), items (name->item),
ownedItems (name->quantity including stash/courier), core (chosen ally or nil).
Unit: index,handle,name,team,pos,hp,maxHp,hpPct,mana,maxMana,manaPct,
range,damage,armorFactor,moveSpeed,attackPoint,attackPeriod,projectileSpeed,
attackTarget (index or nil),attacking,alive,visible,illusion,mods (set),
stunned,rooted,silenced,muted,disarmed,invulnerable,attackImmune,magicImmune,
channeling,casting,level,role (1..5 or nil),recentDamage,healthLossRate,facing.
Ability/item: handle,name,index,level,castable,range,castPoint,cooldown,manaCost,
charges,secondaryCharges,behavior (number),targetTeam (number),hidden,passive,
inPhase,damage,specials (named values),item (boolean),slot (number).
Rune: handle,index,pos,type. Camp: index,pos,box={min,max},type. Tree: index,handle,pos.
Missing information stays nil/unknown when required for correctness; known
booleans default false. Runtime adapter owns capability diagnosis.

Modes module: B.modes.candidates(s) -> list of
{name,desire,reason,target (unit optional),pos (optional),intent(optional),key(optional)}.
B.modes.act(s,mode) -> intent or nil; B.modes.reset() clears state.
Threat: B.threat.at(s,pos)->number, B.threat.balance(s,pos,r)->friendly,enemy
(weighted hp/level strength), B.threat.safeEngage(s,target)->bool;
B.threat.safety(s)-> emergency mode or nil; B.threat.retreat(s)->safe position.
Map: B.map.home(s), B.map.lanePoint(s,lane), B.map.wardSpots(s)->{pos,...}[],
B.map.friendlyTower(s,lane), B.map.classify(pos).

Intent: {kind='move'/'attack'/'hold'/'cast'/'rune'/'level'/'quickbuy'/'interact',
pos,target (unit/rune),ability (ability/item),castType='target'/'position'/'none',
reason,priority (optional),allowTower (optional),wardType(optional),
itemName(optional),emergency(optional)}. One executor serializes all actions.
B.hero.consider(s,mode)->intent or nil; B.hero.level(s)->level intent or nil.
B.items.consider(s,mode)->intent or nil; B.items.purchase(s)->quickbuy intent or nil.
These return proposals, never assume success. B.items.reset(), B.hero.reset()
optional; mode timers must tolerate retries and actual observable outcomes.
Executor performs final validity/range/type checks and cast/attack locks;
priority actions cannot cancel a Charge/TP/channel except emergency or Bot OFF.
