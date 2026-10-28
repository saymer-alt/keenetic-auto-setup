'use strict';
const words={
 ru:{
  scope:'Экспериментальная версия: только локальный доступ. Перед работой с роутером требуется проверка безопасности.',status:'Состояние',unknown:'Состояние сети не проверено',binary:'Файлы: Mihomo {m}; MagiTrickle {mt}. Наличие файла не означает работающий сервис.',present:'есть',absent:'не найден',refresh:'Обновить сведения',
  config:'Конфигурация Mihomo',configHelp:'Загрузите полный готовый config.yaml либо вставьте YAML. Импорт выполняет штатный KAS. Подписки и ключи не сохраняются в браузере.',fileLabel:'Файл YAML (если выбран, он имеет приоритет):',pasteLabel:'Или вставьте полный YAML:',warning:'Внимание: применение может временно остановить Mihomo. Предыдущая конфигурация сохраняется и откатывается штатным импортером при предусмотренных им ошибках. Во время операции не перезагружайте роутер.',apply:'Применить YAML',confirm:'Заменить текущий config.yaml? Mihomo может быть временно перезапущен.',applying:'Импорт выполняется. Не выключайте роутер…',importOk:'Импортер завершён успешно. Код выхода: {exit}',importFail:'Импортер сообщил об ошибке. Код выхода: {exit}. Подробности и фактическое состояние проверьте через Doctor/SSH. {code}',importNone:'Импорт ещё не выполнялся.',importError:'Не удалось выполнить запрос импорта: {code}',fileTooLarge:'YAML слишком большой (лимит 1 МиБ).',emptyFile:'Выберите YAML или вставьте его содержимое.',
  providers:'Список серверов подписки',providersHelp:'Если администратор включил экспорт, можно скачать совместимый с Mihomo Unified Generator JSON: только имена узлов и провайдеров, без паролей и адресов. Затем в генераторе выберите «Импорт узлов из работающего Mihomo» → «Загрузить .json». Сам Mihomo не изменяется.',providersDownload:'Скачать JSON имён узлов',providersDisabled:'Экспорт не включён администратором',providersWorking:'Получаем список из работающего Mihomo…',providersSuccess:'Файл имён узлов сохранён. Загрузите его в Mihomo Builder и выберите исключения.',providersError:'Не удалось получить имена: {code}. Проверьте доступность локального API Mihomo и его secret.',
  doctor:'Диагностика Doctor',help:'Запуск штатного Doctor по запросу. Результат не означает, что маршрутизация каждого клиента проверена.',run:'Запустить Doctor',copy:'Копировать отчёт',details:'Реальный вывод команды',running:'Doctor выполняется…',finished:'Команда завершена; код выхода: {exit}',failed:'Команда не завершилась успешно; код выхода: {exit}; ошибка: {code}',error:'Не удалось выполнить запрос: {code}',footer:'При сбое импорта не заявляйте об откате без фактической проверки. Перед отправкой диагностического отчёта проверьте его вручную.',timestamp:'Время: {time}',notrun:'Doctor ещё не запускался.'
 },
 en:{
  scope:'Experimental loopback-only prototype. Security review is required before router deployment.',status:'Status',unknown:'Network health has not been tested',binary:'Files: Mihomo {m}; MagiTrickle {mt}. Presence does not prove service health.',present:'found',absent:'not found',refresh:'Refresh evidence',
  config:'Mihomo configuration',configHelp:'Upload a complete config.yaml or paste YAML. The canonical KAS importer does the work. Browser storage does not retain your secrets.',fileLabel:'YAML file (takes precedence if selected):',pasteLabel:'Or paste complete YAML:',warning:'Warning: applying may temporarily stop Mihomo. The canonical importer maintains previous-config backup and rollback for the failures it handles. Do not reboot the router mid-operation.',apply:'Apply YAML',confirm:'Replace current config.yaml? Mihomo might restart temporarily.',applying:'Import is running. Do not power off the router…',importOk:'Importer finished successfully. Exit code: {exit}',importFail:'Importer failed. Exit code: {exit}. Check the actual state with Doctor/SSH. {code}',importNone:'No import has been started.',importError:'Import request failed: {code}',fileTooLarge:'YAML exceeds 1 MiB.',emptyFile:'Select a YAML file or paste its contents.',
  providers:'Subscription server names',providersHelp:'If the administrator enabled export, download a JSON compatible with Mihomo Unified Generator: provider and node names only, no server addresses or passwords. In the builder use “Import nodes from running Mihomo” → “Upload .json”. This does not change Mihomo.',providersDownload:'Download node names JSON',providersDisabled:'Export is not enabled by the administrator',providersWorking:'Reading active Mihomo providers…',providersSuccess:'Names JSON saved. Upload it to Mihomo Builder and choose exclusions.',providersError:'Unable to read names: {code}. Check the local Mihomo API and its secret.',
  doctor:'Doctor diagnostics',help:'Run the canonical Doctor on demand. This does not prove every client route.',run:'Run Doctor',copy:'Copy report',details:'Original command output',running:'Doctor is running…',finished:'Command finished; exit code: {exit}',failed:'Command did not complete successfully; exit code: {exit}; error: {code}',error:'Request failed: {code}',footer:'Do not claim rollback without checking the actual router state. Review diagnostics manually before sharing.',timestamp:'Time: {time}',notrun:'Doctor has not been run yet.'
 }
};
let lang=(navigator.language||'en').toLowerCase().startsWith('ru')?'ru':'en';
try{const s=localStorage.getItem('kas_lang');if(s==='ru'||s==='en')lang=s;}catch(_){}
let statusData=null,doctorData=null,busy=false,importData=null,submitting=false,pollTimer=null,importMessage='';
let exporting=false,providerMessage='';
const el=id=>document.getElementById(id);
const t=(key,params={})=>{
 const value=words[lang][key]??words.en[key]??key;
 return value.replace(/\{(\w+)\}/g,(_,k)=>String(params[k]??''));
};
const set=(id,value)=>{el(id).textContent=value;};
function draw(){
 document.documentElement.lang=lang;
 for(const [id,key] of [['scope','scope'],['status-heading','status'],['refresh','refresh'],['config-heading','config'],['config-help','configHelp'],['file-label','fileLabel'],['paste-label','pasteLabel'],['config-warning','warning'],['apply','apply'],['providers-heading','providers'],['providers-help','providersHelp'],['providers-download','providersDownload'],['doctor-heading','doctor'],['doctor-help','help'],['run','run'],['copy','copy'],['details-label','details'],['footer','footer']])set(id,t(key));
 set('status-text',statusData?t('unknown')+' — '+t('timestamp',{time:statusData.timestamp}):t('unknown'));
 set('binary-text',statusData?t('binary',{m:t(statusData.mihomo_binary?'present':'absent'),mt:t(statusData.magitrickle_binary?'present':'absent')}):'');
 const runningImport=importData?.state==='RUNNING';
 let message=t('importNone');
 if(importData){
  if(runningImport)message=t('applying');
  else if(importData.state==='OK')message=t('importOk',{exit:importData.exit_code});
  else if(importData.state==='FAIL'||importData.error_code&&importData.error_code!=='NO_OPERATION')message=t('importFail',{exit:importData.exit_code??'?',code:importData.error_code??'UNKNOWN'});
 }
 if(importMessage)message=importMessage;
 set('config-state',message);
 el('apply').disabled=submitting||runningImport;
 set('providers-state',exporting?t('providersWorking'):providerMessage);
 el('providers-download').disabled=exporting;
 set('doctor-state',busy?t('running'):doctorData?((doctorData.error_code||doctorData.exit_code!==0)?t('failed',{exit:doctorData.exit_code??'?',code:doctorData.error_code??'EXIT_NONZERO'}):t('finished',{exit:doctorData.exit_code}))+ ' — '+t('timestamp',{time:doctorData.timestamp}):t('notrun'));
 set('output',doctorData?.details||'');
 el('copy').disabled=!doctorData||!doctorData.details;el('run').disabled=busy||runningImport;
 el('ru').setAttribute('aria-pressed',String(lang==='ru'));el('en').setAttribute('aria-pressed',String(lang==='en'));
}
async function refresh(){
 try{const resp=await fetch('/api/status',{cache:'no-store'});if(!resp.ok)throw Error('HTTP '+resp.status);statusData=await resp.json();}
 catch(e){statusData=null;set('status-text',t('error',{code:String(e)}));return;}
 draw();
}
async function runDoctor(){
 if(busy||importData?.state==='RUNNING')return;busy=true;draw();
 try{const resp=await fetch('/api/doctor',{method:'POST',headers:{'Content-Type':'application/json'},body:'{}',cache:'no-store'});
  doctorData=await resp.json();if(!resp.ok&&!doctorData.error_code)doctorData.error_code='HTTP_'+resp.status;}
 catch(e){doctorData={error_code:String(e),timestamp:new Date().toISOString(),details:''};}
 finally{busy=false;draw();}
}
function schedulePoll(){
 if(pollTimer!==null)return;
 pollTimer=setTimeout(()=>{pollTimer=null;refreshImport();},1500);
}
async function refreshImport(){
 try{
  const resp=await fetch('/api/config/operation',{cache:'no-store'});
  if(!resp.ok)throw Error('HTTP '+resp.status);
  importData=await resp.json();
  importMessage='';
 }catch(e){importMessage=t('importError',{code:String(e)});}
 finally{draw();if(importData?.state==='RUNNING')schedulePoll();}
}
async function applyYAML(){
 if(submitting||importData?.state==='RUNNING')return;
 const file=el('config-file').files[0];
 const pasted=el('yaml-paste').value;
 if(!file&&!pasted){importMessage=t('emptyFile');draw();return;}
 const limit=1024*1024;
 let bytes;
 if(file){
  if(file.size>limit){importMessage=t('fileTooLarge');draw();return;}
  bytes=new Uint8Array(await file.arrayBuffer());
 }else{bytes=new TextEncoder().encode(pasted);}
 if(bytes.length===0){importMessage=t('emptyFile');draw();return;}
 if(bytes.length>limit){importMessage=t('fileTooLarge');draw();return;}
 if(!window.confirm(t('confirm')))return;
 submitting=true;importMessage='';draw();
 try{
  const resp=await fetch('/api/config/import',{method:'POST',headers:{'Content-Type':'application/x-yaml','X-KAS-Confirm':'apply'},body:bytes,cache:'no-store'});
  importData=await resp.json();
  if(resp.status!==202){importMessage=t('importError',{code:importData?.error_code??'HTTP_'+resp.status});}
  else{
   el('config-file').value='';el('yaml-paste').value='';
   schedulePoll();
  }
 }catch(e){importMessage=t('importError',{code:String(e)});}
 finally{submitting=false;draw();}
}
for(const l of ['ru','en'])el(l).addEventListener('click',()=>{lang=l;try{localStorage.setItem('kas_lang',l)}catch(_){}draw();});
el('refresh').addEventListener('click',refresh);
el('run').addEventListener('click',runDoctor);
async function exportProviders(){
 if(exporting)return;
 exporting=true;providerMessage='';draw();
 try{
  const response=await fetch('/api/providers/names',{cache:'no-store',credentials:'same-origin'});
  if(!response.ok){
   if(response.status===404){providerMessage=t('providersDisabled');return;}
   let code='HTTP_'+response.status;
   try{const error=await response.json();code=error.error_code||code;}catch(_){}
   providerMessage=t('providersError',{code});return;
  }
  const file=await response.blob();
  if(file.size>1024*1024){providerMessage=t('providersError',{code:'RESPONSE_TOO_LARGE'});return;}
  const url=URL.createObjectURL(file);
  const a=document.createElement('a');
  a.href=url;a.download='mihomo-providers-names.json';
  document.body.appendChild(a);a.click();a.remove();
  setTimeout(()=>URL.revokeObjectURL(url),1000);
  providerMessage=t('providersSuccess');
 }catch(_){providerMessage=t('providersError',{code:'NETWORK_ERROR'});}
 finally{exporting=false;draw();}
}
el('apply').addEventListener('click',applyYAML);
el('providers-download').addEventListener('click',exportProviders);
el('copy').addEventListener('click',async()=>{if(!doctorData?.details)return;try{await navigator.clipboard.writeText(doctorData.details)}catch(_){}});
draw();refresh();refreshImport();
