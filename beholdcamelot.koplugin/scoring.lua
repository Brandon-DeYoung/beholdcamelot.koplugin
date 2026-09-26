-- Active-face scoring data. Every oriented realm card counts, regardless of zone.
local S = {}
local function f(keys,u,p) return {keys=keys or {},unrest=u or 0,prosperity=p or 0} end
S.faces = {
 crafts={f(),f({wheel=1}),f({wheel=2}),f({wheel=2},0,1)},
 host={f({military=1}),f({military=2}),f({military=3},2),f({military=4},4)},
 works={f({wheel=1}),f({wheel=2}),f({wheel=2},0,1),f({wheel=3})},
 council={f({sprout=1,bag=1,lyre=1},0,1),f({bag=1,lyre=1},0,2),f({military=2},1),f({military=1},2)},
 customs={f({lyre=1}),f({military=1},4),f({lyre=2}),f({wheel=1,lyre=1},0,3)},
 kin={f({military=2},5),f({bag=1,sprout=1},0,1),f({military=2,bag=1},2),f({},2)},
 lake={f(),f({military=1,ship=1}),f({sprout=1,ship=1},0,2),f({sprout=2,ship=2},0,1)},
 gaul={f({ship=1}),f({ship=2}),f({sprout=1,luxury=1,bag=2},1),f({ship=3,bag=1},3)},
 allies={f({sprout=1}),f({sprout=1,bag=1}),f({sprout=2,bag=1},1),f({sprout=2,bag=1,ship=1},2)},
 wounds={f({},3),f({bag=1,ship=1,sprout=1},1),f({bag=1}),f({},4)},
 grail={f({military=2}),f({lyre=3}),f({lyre=2,bag=1,ship=1},1),f({lyre=3},0,2)},
 marches={f(),f({military=1,lyre=1}),f({military=1,lyre=1,bag=1},1),f({military=2,lyre=1},0,2)},
 camelot={f(),f({lyre=1}),f({lyre=1},2),f({lyre=4},4)},
 dues={f({},0,1),f({bag=1},0,1),f({bag=2},1),f({bag=4},5)},
 trade={f({bag=1}),f({bag=1,luxury=1}),f({bag=1,lyre=1}),f({bag=2})},
 claims={f(),f(),f({military=1,wheel=1}),f({military=2,wheel=1},1)},
}
S.order={"military","wheel","lyre","bag","sprout","luxury","ship"}
S.rules={
 crafts={"1 per Court at level 3+","1 per Court at level 2+","2 per Court at level 4","2 per Court at level 3+"},
 host={"0","1","1 per 3 military","1 per 2 military"},
 works={"3 if The Crown","3 if The Fellowship","3 if Arthur's Empire","2 per Provision at level 4"},
 council={"7 if The Last Battle active","1 per 2 prosperity","4 if The Fellowship; if Lancelot active, 1 per 2 controlled wealth","4 if The Fellowship"},
 customs={"2 per red-banner Court","2 per controlled Holding","0","7 if The Grail Quest"},
 kin={"4 if Arthur active","1 per blue-banner card","1 per 2 wealth on all Holding cards","9 if Sarras active; -5 if Crown-era"},
 lake={"4 if Arthur's Empire","0; +4 prosperity if Gawain; +3 unrest if Gareth or Gaheris","1 per 3 bags","3 per Provision at level 4"},
 gaul={"-3","1 per 2 ships; if controlled, each 2 unrest also counts as 1 military","1 per Action at level 3+","1 per bag"},
 allies={"1","2","1 per Holding card","2 per Holding card"},
 wounds={"0","4","1","0"},
 grail={"1","3 if Quest-era; -3 if Crown-era","1 per 2 bags","8 if The Grail Quest"},
 marches={"1","2","3 if Arthur's Empire; 6 if The Grail Quest"},
 camelot={"1 per 3 wheels","1 per 2 wheels","1 per wheel","3 per Ally"},
 dues={"1 per 3 sprouts","1 per 2 sprouts","1 per sprout","2 per sprout"},
 trade={"1 per sprout","2 per luxury","1 per 3 lyres","2 per Action at level 4"},
 claims={"1","2","3","4"},
}
S.rules.marches[3]="3"
S.rules.marches[4]="3 if Arthur's Empire; 6 if The Grail Quest; +1 prosperity per 2 lyres"
-- Plain ASCII remains reliable on Kindle fonts; names are included in full text.
S.symbols={military="X|",wheel="(+) ",lyre="|U|",bag="($)",sprout="\\|/",luxury="::: ",ship="\\_/>"}
function S.icons(id,l,verbose)
 local a={}
 for _,k in ipairs(S.order) do local n=S.faces[id][l].keys[k]; if n then a[#a+1]=(verbose and k or S.symbols[k])..":"..n end end
 local d=S.faces[id][l]
 a[#a+1]="Unrest:"..d.unrest; a[#a+1]="Prosperity:"..d.prosperity
 return table.concat(a,"  ")
end
function S.calculate(g,types,faces,wealth)
 local L=g.levels; local realm=g.realm_level; local crown_era=realm<=2
 local K={military=0,wheel=0,lyre=0,bag=0,sprout=0,luxury=0,ship=0}
 local T={}; local u,p,levels,blue,redinst,high,holdingwealth,materials=0,0,0,0,0,0,0,0
 local function count(t,min,exact)
  local n=0; for id,l in pairs(L) do if types[id] and types[id][l]==t and (not min or l>=min) and (not exact or l==exact) then n=n+1 end end; return n
 end
 for id,l in pairs(L) do if S.faces[id] then
  local d=S.faces[id][l]; for k,v in pairs(d.keys) do K[k]=K[k]+v end
  u=u+d.unrest; p=p+d.prosperity; levels=levels+l
  local t=types[id][l]; T[t]=(T[t] or 0)+1
  local play=faces[id][l].play or ""
  if play:find("Quest-era",1,true) then blue=blue+1 end
  if t=="Court" and (play:find("Crown-era",1,true) or play:find("The Crown only",1,true)) then redinst=redinst+1 end
  if l>=3 then high=high+1 end
  holdingwealth=holdingwealth+((wealth[id] or {})[l] or 0)
  materials=materials+(tonumber((faces[id][l].store or ""):match("(%d+) material")) or 0)
 end end
 if realm==1 then u=u+5 end
 if L.lake==2 then if L.kin==1 then p=p+4 elseif L.kin==2 or L.kin==3 then u=u+3 end end
 if L.marches==4 then p=p+math.floor(K.lyre/2) end
 local controlled=0; local held={}
 for _,id in ipairs(g.controlled or {}) do held[id]=true; controlled=controlled+((wealth[id] or {})[L[id]] or 0) end
 if held.gaul and L.gaul==2 then K.military=K.military+math.floor(u/2) end
 local function yes(b,n) return b and n or 0 end
 local scores={
 crafts={count("Court",3),count("Court",2),2*count("Court",nil,4),2*count("Court",3)},
 host={0,1,math.floor(K.military/3),math.floor(K.military/2)},
 works={yes(realm==1,3),yes(realm==2,3),yes(realm==3,3),2*count("Provision",nil,4)},
 council={yes(L.kin==4,7),math.floor(p/2),yes(realm==2,4)+yes(L.lake==2,math.floor(controlled/2)),yes(realm==2,4)},
 customs={2*redinst,2*#(g.controlled or {}),0,yes(realm==4,7)},
 kin={yes(L.council==3,4),blue,math.floor(holdingwealth/2),yes(L.grail==4,9)-yes(crown_era,5)},
 lake={yes(realm==3,4),0,math.floor(K.bag/3),3*count("Provision",nil,4)},
 gaul={-3,math.floor(K.ship/2),count("Action",3),K.bag},
 allies={1,2,T.Holding or 0,2*(T.Holding or 0)},
 wounds={0,4,1,0},
 grail={1,crown_era and -3 or 3,math.floor(K.bag/2),yes(realm==4,8)},
 marches={1,2,3,realm==4 and 6 or (realm==3 and 3 or 0)},
 camelot={math.floor(K.wheel/3),math.floor(K.wheel/2),K.wheel,3*(T.Ally or 0)},
 dues={math.floor(K.sprout/3),math.floor(K.sprout/2),K.sprout,2*K.sprout},
 trade={K.sprout,2*K.luxury,math.floor(K.lyre/3),2*count("Action",nil,4)},
 claims={1,2,3,4},
 }
 local cv,detail=0,{}
 for id,l in pairs(L) do if scores[id] then detail[id]=scores[id][l]; cv=cv+detail[id] end end
 local nv=({K.bag,p,7*(T.Ally or 0),math.floor(levels/3)})[realm]
 local penalty=-2*math.max(0,u-p)
 local rival,breakdown=nil,{}
 local function term(label,formula,points,active)
  if active==nil then active=true end
  local value=active and points or 0
  breakdown[#breakdown+1]={label=label,formula=formula,points=value,active=active}
  rival=(rival or 0)+value
 end
 if g.rival=="Morgan le Fay" then
  term("Base","61",61)
  term("The Crown / The Fellowship: Holding cards","6 x "..(T.Holding or 0).." active Holding cards",6*(T.Holding or 0),crown_era)
  term("Arthur's Empire: lyres","(13 - "..K.lyre.." lyres) x 3",(13-K.lyre)*3,realm==3)
  term("The Grail Quest: bags","(19 - "..K.bag.." bags) x 5",(19-K.bag)*5,realm==4)
 elseif g.rival=="Mordred" then
  term("Base","44",44)
  term("Unrest","1 x "..u.." total unrest (before prosperity coverage)",u)
  term("Sprouts","(9 - "..K.sprout.." sprouts) x 4",(9-K.sprout)*4)
  term("The Crown / The Fellowship: ships","2 x "..K.ship.." ships",2*K.ship,crown_era)
  term("Arthur's Empire: high-level cards","2 x "..high.." level-3+ cards",2*high,realm==3)
  term("The Grail Quest: high-level cards","3 x "..high.." level-3+ cards",3*high,realm==4)
 elseif g.rival=="King Lot" then
  term("Base","50",50)
  term("Controlled wealth","(15 - "..controlled.." controlled wealth) x 3",(15-controlled)*3)
  term("11+ military: prosperity",K.military.." military; 1 x "..p.." prosperity",p,K.military>=11)
  term("10 or less military: prosperity",K.military.." military; 2 x "..p.." prosperity",2*p,K.military<=10)
 elseif g.rival=="Lucius" then
  term("Base","62",62)
  term("11+ active Holding wealth: non-blue cards",holdingwealth.." active Holding wealth; 2 x (16 - "..blue.." blue-banner cards)",2*(16-blue),holdingwealth>=11)
  term("10 or less active Holding wealth: ships",holdingwealth.." active Holding wealth; (10 - "..K.ship.." ships) x 6",(10-K.ship)*6,holdingwealth<=10)
  term("Non-Arthur's Empire: printed materials","(20 - "..materials.." printed material icons) x 2; NOT stored materials",(20-materials)*2,realm~=3)
 end
 if rival then term("Rival difficulty: "..(g.rival_difficulty or "Normal"),string.format("%+d Renown modifier",g.rival_modifier or 0),g.rival_modifier or 0) end
 return {total=controlled+cv+nv+penalty,rival=rival,rival_breakdown=breakdown,civ=cv,realm=nv,controlled=controlled,penalty=penalty,unrest=u,prosperity=p,keys=K,cards=detail}
end
return S
