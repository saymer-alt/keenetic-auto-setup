// Versioned interpretation of the existing redacted Doctor report. No new probes.
(function(root){
'use strict';
const versions=new Set(['1.2.18','1.2.19']);
function parse(data){
 const unknown={supported:false,facts:{},findings:[]};
 if(!data||data.error_code||typeof data.details!=='string'||data.details.length>262144)return unknown;
 const text=data.details.replace(/\x1b\[[0-9;]*m/g,'').replace(/\r\n/g,'\n');
 if(!text.startsWith('=== Mihomo Doctor (read-only diagnostic) ===\n')||/[\x00-\x08\x0b-\x1f\x7f]/.test(text))return unknown;
 const footer=text.match(/=== Mihomo Doctor Summary ===\nOK: +([0-9]{1,6})\nWARN: ([0-9]{1,6})\nFAIL: ([0-9]{1,6})\nINFO: ([0-9]{1,6})\n\n\[(OK|WARN|FAIL)\] Overall status: (OK|WARN|FAIL)\n?$/);
 if(!footer||text.split('=== Mihomo Doctor Summary ===').length!==2)return unknown;
 const counts=footer.slice(1,5).map(Number),verdict=counts[2]?'FAIL':counts[1]?'WARN':'OK';
 const summary=data.summary;
 if(footer[5]!==verdict||footer[6]!==verdict||data.exit_code!==({OK:0,WARN:1,FAIL:2})[verdict]||!summary||summary.verdict!==verdict||!['ok','warn','fail','info'].every((k,i)=>summary[k]===counts[i]))return unknown;
 const versionLines=[...text.matchAll(/^\[INFO\] Doctor version: (\S+)$/gm)];
 if(versionLines.length!==1||!versions.has(versionLines[0][1]))return unknown;
 const facts={},findings=[],seen=new Set();let section='other';
 const put=(key,value)=>{if(seen.has(key)){delete facts[key];return;}seen.add(key);if(value!==undefined)facts[key]=value;};
 const amount=(free,total)=>Number.isSafeInteger(+free)&&Number.isSafeInteger(+total)&&+free>=0&&+free<=+total&&+total<=1000000000?{free:+free,total:+total}:undefined;
 for(const line of text.split('\n')){
  if(line==='=== What needs attention ==='||line==='=== Mihomo Doctor Summary ===')break;
  const header=line.match(/^===== ([0-9]+[ab]?)\. .* =====$/);if(header){section=header[1];continue;}
  const finding=line.match(/^\[(WARN|FAIL)\] +(.{1,2048})$/);
  if(finding&&section)findings.push({severity:finding[1],section,evidence:finding[2]});
  const row=line.match(/^\[(INFO|OK|WARN|FAIL)\] +(.+)$/);if(!row)continue;
  const value=row[2];let m;
  if(section==='1'){
   if((m=value.match(/^Router: (?:model: )?(.{1,160})$/)))put('model',m[1]);
   if((m=value.match(/^KeeneticOS: ([0-9][A-Za-z0-9.+~-]{0,63})$/)))put('os',m[1]);
   if((m=value.match(/^Entware \/opt mount: source=([^;]{1,160}); mountpoint=([^;]{1,160}); filesystem=([a-z0-9]{1,20}); class=(internal|external|ram|unknown)$/)))put('storage',{source:m[1],mountpoint:m[2],filesystem:m[3],class:m[4]});
   if((m=value.match(/^RAM total: (\d{1,10}) MB, available: (\d{1,10}) MB$/)))put('ram',amount(m[2],m[1]));
   if((m=value.match(/^Swap: (\d{1,10}) MB \(free (\d{1,10}) MB\)$/)))put('swap',amount(m[2],m[1]));
   if((m=value.match(/^Free space on \/(opt|tmp): (\d{1,10}) MB of (\d{1,10}) MB \(\d{1,3}% free\)$/)))put(m[1],amount(m[2],m[3]));
  }
  if(section==='5'){
   if(/^Mihomo is running \(\d+ process\(es\)\)/.test(value))put('mihomo','running');
   if(/^Mihomo service is stopped|^Mihomo is not running and/.test(value))put('mihomo','stopped');
  }
  if(section==='6b'){
   if(/^magitrickled process is running \(\d+ process\(es\)\)$/.test(value))put('magitrickle','running');
   if(/^magitrickled process is not running -/.test(value))put('magitrickle','stopped');
  }
  if(section==='8'){
   if(/^Watchdog scheduled in /.test(value))put('watchdog','scheduled');
   if(/^Watchdog not scheduled in |^Watchdog not installed/.test(value))put('watchdog','not_scheduled');
  }
  if(section==='8b'){
   if((m=value.match(/^Available history: (\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) -> (\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) \(rotation keeps ~300-500 lines; tmpfs: lost on reboot\)$/)))put('history',{start:m[1],end:m[2]});
   if((m=value.match(/^Healthy heartbeats \(\[OK\] All good\) on record: (\d{1,9})$/)))put('heartbeats',+m[1]);
   if(value==='No restarts or problem detections in the available history'){put('restarts',0);put('rate_limits',0);}
   if((m=value.match(/^Problem events on record: (\d{1,9}) restart\(s\), (\d{1,9}) rate-limited run\(s\) \(problem detected, restart suppressed by cooldown\)$/))){put('restarts',+m[1]);put('rate_limits',+m[2]);}
  }
 }
 if(findings.filter(f=>f.severity==='WARN').length>counts[1]||findings.filter(f=>f.severity==='FAIL').length>counts[2])return unknown;
 return {supported:true,version:versionLines[0][1],facts,findings};
}
const labels={
 ru:{title:"Результаты диагностики Doctor",scope:"Сводка последней проверки Doctor. Она показывает состояние роутера, но не проверяет доступность Интернета у каждого устройства.",unknown:"Нет данных",unsupported:"Не удалось построить сводку по отчёту Doctor. Откройте полный технический отчёт.",model:'Роутер',os:'KeeneticOS',storage:"Накопитель Entware (/opt)",internal:'Внутренняя память',external:'Внешний накопитель',ram:'Оперативная память',ramStorage:"Хранилище в оперативной памяти",opt:'Свободное место /opt',tmp:'Свободное место /tmp',memory:"Доступная оперативная память",swap:"Доступное место в файле подкачки",amount:'{free} из {total} МБ',mihomo:'Mihomo',magitrickle:'MagiTrickle',running:'Процесс запущен',stopped:'Процесс не запущен',watchdog:"Расписание проверки watchdog",scheduled:'Настроено',not_scheduled:'Не настроено',heartbeats:"Успешные проверки watchdog",restarts:"Перезапуски в истории watchdog",rate_limits:"Превышения лимита перезапусков",history:"Период журнала watchdog",historyNote:"Показан только доступный журнал. После перезагрузки или очистки старых записей история может быть неполной. Время указано как в журнале.",findings:"Обнаруженные проблемы",noFindings:"Doctor не обнаружил ошибок или предупреждений.",unmapped:"Не все замечания удалось распознать. Подробности есть в полном техническом отчёте.",WARN:'Предупреждение',FAIL:'Ошибка',evidence:"Подробности проверки",system:'Система и ресурсы',service:"Работа служб",network:'Сеть',config:'Конфигурация',other:"Дополнительная проверка"},
 en:{title:'Doctor overview',scope:'From the last Doctor run. These checks cover the router, not every client or website.',unknown:'Could not determine',unsupported:'Overview unavailable: the report format or completion could not be verified. Open the original report.',model:'Router',os:'KeeneticOS',storage:'Entware /opt storage',internal:'Internal storage',external:'External storage',ram:'RAM',ramStorage:'RAM-backed storage',opt:'Free space on /opt',tmp:'Free space on /tmp',memory:'Available RAM',swap:'Free swap',amount:'{free} of {total} MB',mihomo:'Mihomo',magitrickle:'MagiTrickle',running:'Process running',stopped:'Process not running',watchdog:'Watchdog schedule',scheduled:'Configured',not_scheduled:'Not configured',heartbeats:'Healthy watchdog entries',restarts:'Restarts in watchdog history',rate_limits:'Restart rate-limit events',history:'Available watchdog history',historyNote:'Only the retained log interval. Reboot or rotation may shorten the history. Times are as recorded in the log.',findings:'Findings',noFindings:'No errors or warnings in the current Doctor checks.',unmapped:'Some findings were not recognized. See the original report.',WARN:'Warning',FAIL:'Error',evidence:'Technical evidence',system:'System and resources',service:'Service',network:'Network',config:'Configuration',other:'Doctor check'}
};
function describe(report,language){
 const w=labels[language]||labels.en,f=report.facts;
 const amount=v=>v?w.amount.replace('{free}',v.free).replace('{total}',v.total):w.unknown;
 const storage=f.storage?({internal:w.internal,external:w.external,ram:w.ramStorage,unknown:w.unknown}[f.storage.class]+' · '+f.storage.filesystem+' · '+f.storage.source):w.unknown;
 return [['model',f.model||w.unknown],['os',f.os||w.unknown],['storage',storage],['opt',amount(f.opt)],['tmp',amount(f.tmp)],['memory',amount(f.ram)],['swap',amount(f.swap)],['mihomo',w[f.mihomo]||w.unknown],['magitrickle',w[f.magitrickle]||w.unknown],['watchdog',w[f.watchdog]||w.unknown],['heartbeats',f.heartbeats??w.unknown],['restarts',f.restarts??w.unknown],['rate_limits',f.rate_limits??w.unknown],['history',f.history?f.history.start+' → '+f.history.end:w.unknown]].map(([key,value])=>({label:w[key],value:String(value)}));
}
function render(container,data,language){
 container.replaceChildren();container.hidden=!data;if(!data)return;
 const w=labels[language]||labels.en,doc=container.ownerDocument||document;
 const add=(tag,text,parent=container)=>{const node=doc.createElement(tag);node.textContent=text;parent.appendChild(node);return node;};
 add('h2',w.title);const report=parse(data);
 if(!report.supported){add('p',w.unsupported);return;}
 add('p',w.scope).className='caption';
 const grid=add('dl','');grid.className='doctor-facts';
 for(const item of describe(report,language)){const cell=add('div','',grid);add('dt',item.label,cell);add('dd',item.value,cell);}
 add('p',w.historyNote).className='caption';add('h3',w.findings);
 for(const finding of report.findings){
  const category=({'1':'system','3':'service','4':'config','5':'service','6':'network','6a':'service','6b':'service','7':'network','8':'watchdog','8b':'watchdog','9':'network','10':'service'})[finding.section]||'other';
  const item=add('details','');item.className='doctor-finding';add('summary',w[finding.severity]+' · '+w[category],item);add('p',finding.evidence,item);
 }
 if(!data.summary.warn&&!data.summary.fail)add('p',w.noFindings);
 else if(report.findings.length<data.summary.warn+data.summary.fail)add('p',w.unmapped);
}
const api={parse,describe,render,labels};
if(typeof module==='object'&&module.exports)module.exports=api;else root.kasDoctorReport=api;
})(globalThis);
