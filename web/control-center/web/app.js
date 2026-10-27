'use strict';
const words={
 ru:{scope:'Прототип: только локальный доступ; сеть и конфигурация не изменяются.',status:'Состояние',unknown:'Состояние сети не проверено',binary:'Файлы: Mihomo {m}; MagiTrickle {mt}. Наличие файла не означает работающий сервис.',present:'есть',absent:'не найден',refresh:'Обновить сведения',doctor:'Диагностика Doctor',help:'Запуск штатного Doctor по запросу. Результат не означает, что маршрутизация каждого клиента проверена.',run:'Запустить Doctor',copy:'Копировать отчёт',details:'Реальный вывод команды',running:'Doctor выполняется…',finished:'Команда завершена; код выхода: {exit}',failed:'Команда не завершилась успешно; код выхода: {exit}; ошибка: {code}',error:'Не удалось выполнить запрос: {code}',footer:'Данные диагностики могут содержать персональные сведения. Перед отправкой отчёта проверьте текст вручную.',timestamp:'Время: {time}',notrun:'Doctor ещё не запускался.'},
 en:{scope:'Prototype: loopback access only; no network or configuration changes.',status:'Status',unknown:'Network health has not been tested',binary:'Files: Mihomo {m}; MagiTrickle {mt}. Presence does not prove service health.',present:'found',absent:'not found',refresh:'Refresh evidence',doctor:'Doctor diagnostics',help:'Run the canonical Doctor on demand. This does not prove every client route.',run:'Run Doctor',copy:'Copy report',details:'Original command output',running:'Doctor is running…',finished:'Command finished; exit code: {exit}',failed:'Command did not complete successfully; exit code: {exit}; error: {code}',error:'Request failed: {code}',footer:'Diagnostics may contain private data. Review the text manually before sharing.',timestamp:'Time: {time}',notrun:'Doctor has not been run yet.'}
};
let lang=(navigator.language||'en').toLowerCase().startsWith('ru')?'ru':'en';
try{let s=localStorage.getItem('kas_lang');if(s==='ru'||s==='en')lang=s;}catch(_){}
let statusData=null,doctorData=null,busy=false;
const el=id=>document.getElementById(id);
const t=(key,params={})=>{let value=words[lang][key]??words.en[key]??key;return value.replace(/\{(\w+)\}/g,(_,k)=>String(params[k]??''));};
const set=(id,value)=>{el(id).textContent=value;};
function draw(){
 document.documentElement.lang=lang;
 for(const [id,key] of [['scope','scope'],['status-heading','status'],['refresh','refresh'],['doctor-heading','doctor'],['doctor-help','help'],['run','run'],['copy','copy'],['details-label','details'],['footer','footer']])set(id,t(key));
 set('status-text',statusData?t('unknown')+' — '+t('timestamp',{time:statusData.timestamp}):t('unknown'));
 set('binary-text',statusData?t('binary',{m:t(statusData.mihomo_binary?'present':'absent'),mt:t(statusData.magitrickle_binary?'present':'absent')}):'');
 set('doctor-state',busy?t('running'):doctorData?((doctorData.error_code||doctorData.exit_code!==0)?t('failed',{exit:doctorData.exit_code??'?',code:doctorData.error_code??'EXIT_NONZERO'}):t('finished',{exit:doctorData.exit_code}))+ ' — '+t('timestamp',{time:doctorData.timestamp}):t('notrun'));
 set('output',doctorData?.details||'');
 el('copy').disabled=!doctorData||!doctorData.details;el('run').disabled=busy;
 el('ru').setAttribute('aria-pressed',String(lang==='ru'));el('en').setAttribute('aria-pressed',String(lang==='en'));
}
async function refresh(){
 try{const resp=await fetch('/api/status',{cache:'no-store'});if(!resp.ok)throw Error('HTTP '+resp.status);statusData=await resp.json();}
 catch(e){statusData=null;set('status-text',t('error',{code:String(e)}));return;}
 draw();
}
async function runDoctor(){
 if(busy)return;busy=true;draw();
 try{const resp=await fetch('/api/doctor',{method:'POST',headers:{'Content-Type':'application/json'},body:'{}',cache:'no-store'});
  doctorData=await resp.json();if(!resp.ok&&!doctorData.error_code){doctorData.error_code='HTTP_'+resp.status;}}
 catch(e){doctorData={error_code:String(e),timestamp:new Date().toISOString(),details:''};}
 finally{busy=false;draw();}
}
for(const l of ['ru','en'])el(l).addEventListener('click',()=>{lang=l;try{localStorage.setItem('kas_lang',l)}catch(_){}draw();});
el('refresh').addEventListener('click',refresh);
el('run').addEventListener('click',runDoctor);
el('copy').addEventListener('click',async()=>{if(!doctorData?.details)return;try{await navigator.clipboard.writeText(doctorData.details)}catch(_){}});
draw();refresh();
