'use strict';
const words={
 ru:{
  accessHeading:'Доступ к панели',accessHomeOnly:'Разрешать доступ только из домашней сети Home',accessHelp:'По умолчанию ограничение выключено: можно подключаться из других подсетей, включая SSTP/L2TP, если это разрешают маршруты и firewall роутера. Эта опция не открывает порты и не настраивает VPN.',accessSave:'Сохранить',accessLoading:'Читаем настройку доступа…',accessOn:'Ограничение Home включено. Другие подсети, включая VPN, отклоняются.',accessOff:'Ограничение Home выключено. Доступ определяется маршрутами и firewall роутера.',accessError:'Не удалось изменить или прочитать настройку: {code}',accessEnableConfirm:'Разрешить доступ только из Home? Подключение через VPN или другую подсеть может потерять доступ к панели. Восстановить доступ можно из Home или через SSH.',accessDisableConfirm:'Выключить ограничение Home? Панель станет доступна из других подсетей, которым firewall разрешает подключаться к её адресу.',
  scope:'Экспериментальная панель. Доступ к адресу роутера определяется его маршрутами и firewall; пароль и ограничение Home необязательны.',status:'Состояние',unknown:'Состояние сети не проверено',binary:'Файлы: Mihomo {m}; MagiTrickle {mt}. Наличие файла не означает работающий сервис.',present:'есть',absent:'не найден',refresh:'Обновить сведения',
  config:'Конфигурация Mihomo',configHelp:'Загрузите полный готовый config.yaml либо вставьте YAML. Импорт выполняет штатный KAS. Подписки и ключи не сохраняются в браузере.',fileLabel:'Файл YAML (если выбран, он имеет приоритет):',pasteLabel:'Или вставьте полный YAML:',warning:'Внимание: применение может временно остановить Mihomo. Предыдущая конфигурация сохраняется и откатывается штатным импортером при предусмотренных им ошибках. Во время операции не перезагружайте роутер.',apply:'Применить YAML',confirm:'Заменить текущий config.yaml? Mihomo может быть временно перезапущен.',applying:'Импорт выполняется. Не выключайте роутер…',importOk:'Импортер завершён успешно. Код выхода: {exit}',importFail:'Импортер сообщил об ошибке. Код выхода: {exit}. Подробности и фактическое состояние проверьте через Doctor/SSH. {code}',importNone:'Импорт ещё не выполнялся.',importError:'Не удалось выполнить запрос импорта: {code}',fileTooLarge:'YAML слишком большой (лимит 1 МиБ).',emptyFile:'Выберите YAML или вставьте его содержимое.',
  providers:'Список серверов подписки',providersHelp:'Если администратор включил экспорт, можно скачать совместимый с Mihomo Unified Generator JSON: только имена узлов и провайдеров, без паролей и адресов. Затем в генераторе выберите «Импорт узлов из работающего Mihomo» → «Загрузить .json». Сам Mihomo не изменяется.',providersDownload:'Скачать JSON имён узлов',providersDisabled:'Экспорт не включён администратором',providersWorking:'Получаем список из работающего Mihomo…',providersSuccess:'Файл имён узлов сохранён. Загрузите его в Mihomo Builder и выберите исключения.',providersError:'Не удалось получить имена: {code}. Проверьте доступность локального API Mihomo и его secret.',
  filterHeading:'🚫 Фильтрация серверов подписки (предпросмотр и применение)',filterHelp:'Эксперимент: показывает загруженные Mihomo имена и будущие изменения exclude-filter. Применение выполняет штатный импортёр KAS после явного подтверждения; если config.yaml изменился после предпросмотра, импортёр откажет без изменений. Снятие фильтра работает, даже когда исключённые узлы не видны в API. Редактируем только совместимые HTTP-провайдеры; сложный YAML требует обычного импорта.',filterLoad:'Загрузить провайдеры и узлы',filterProviderLabel:'Провайдер:',filterPreview:'Показать фильтр для отмеченных',filterClear:'Показать удаление фильтра',filterHint:'Галочка означает исключить узел. Из ответа Mihomo уже исключённые узлы могут отсутствовать. Перед заменой существующего фильтра проверьте его содержание.',filterNoProvider:'Поддерживаемых HTTP-провайдеров нет',filterExisting:'Существующий exclude-filter: {filter}',filterNoFilter:'не задан',filterLoading:'Читаем локальные данные…',filterLoaded:'Провайдеры загружены. Выберите исключения.',filterNamesUnavailable:'Имена узлов недоступны: {code}. Существующий фильтр можно снять; выбор исключений станет доступен после обновления списка.',filterCannotLoad:'Не удалось прочитать данные: {code}',filterNoNames:'Доступных узлов нет (либо они уже скрыты действующим фильтром).',filterTooMany:'Показаны первые {count} узлов; полный список доступен в JSON-экспорте.',filterPreviewing:'Проверяем изменения…',filterPreviewReady:'Предпросмотр готов. Изменение ещё не применено.',filterPreviewError:'Ошибка предпросмотра: {code}',filterNothing:'Выберите хотя бы один узел.',filterProposed:'Было: {before}\nБудет: {after}\nПока только предпросмотр. Для записи нажмите «Применить показанное изменение».',filterApply:'Применить показанное изменение',filterApplyConfirm:'Применить показанное изменение exclude-filter через штатный импортёр KAS? Mihomo может быть кратковременно перезапущен. Если config.yaml изменился после предпросмотра, применение будет отклонено без изменений.',filterApplying:'Применение выполняется штатным импортёром. Не выключайте роутер…',filterApplyDone:'Штатный импортёр завершён успешно.',filterApplyReady:'Изменение применено штатным импортёром. Список узлов обновлён из работающего Mihomo.',filterApplyNoChange:'Изменение уже соответствует текущей конфигурации; импорт не запускался.',filterApplyError:'Не удалось запустить применение: {code}',filterApplyFail:'Импортёр сообщил об ошибке. Изменение могло не примениться; фактическое состояние проверьте через Doctor/SSH.',
  doctor:'Диагностика Doctor',help:'Запуск штатного Doctor по запросу. Результат не означает, что маршрутизация каждого клиента проверена.',run:'Запустить Doctor',copy:'Копировать отчёт',details:'Реальный вывод команды',running:'Doctor выполняется…',finished:'Команда завершена; код выхода: {exit}',failed:'Команда не завершилась успешно; код выхода: {exit}; ошибка: {code}',error:'Не удалось выполнить запрос: {code}',footer:'При сбое импорта не заявляйте об откате без фактической проверки. Перед отправкой диагностического отчёта проверьте его вручную.',timestamp:'Время: {time}',notrun:'Doctor ещё не запускался.'
 },
 en:{
  accessHeading:'Panel access',accessHomeOnly:'Allow access only from the Home subnet',accessHelp:'Off by default: other subnets, including SSTP/L2TP, can connect when router routing and firewall allow it. This setting does not open ports or configure VPN.',accessSave:'Save',accessLoading:'Reading access policy…',accessOn:'Home-only restriction is enabled. Other subnets, including VPN clients, are rejected.',accessOff:'Home-only restriction is off. Router routing and firewall determine access.',accessError:'Unable to save or read access policy: {code}',accessEnableConfirm:'Restrict access to Home? VPN or other-subnet clients may lose panel access. Recovery requires Home access or SSH.',accessDisableConfirm:'Disable the Home-only restriction? Other subnets allowed by the router firewall will be able to reach the panel.',
  scope:'Experimental panel. Router routing and firewall determine reachability; password and Home-only restriction are optional.',status:'Status',unknown:'Network health has not been tested',binary:'Files: Mihomo {m}; MagiTrickle {mt}. Presence does not prove service health.',present:'found',absent:'not found',refresh:'Refresh evidence',
  config:'Mihomo configuration',configHelp:'Upload a complete config.yaml or paste YAML. The canonical KAS importer does the work. Browser storage does not retain your secrets.',fileLabel:'YAML file (takes precedence if selected):',pasteLabel:'Or paste complete YAML:',warning:'Warning: applying may temporarily stop Mihomo. The canonical importer maintains previous-config backup and rollback for the failures it handles. Do not reboot the router mid-operation.',apply:'Apply YAML',confirm:'Replace current config.yaml? Mihomo might restart temporarily.',applying:'Import is running. Do not power off the router…',importOk:'Importer finished successfully. Exit code: {exit}',importFail:'Importer failed. Exit code: {exit}. Check the actual state with Doctor/SSH. {code}',importNone:'No import has been started.',importError:'Import request failed: {code}',fileTooLarge:'YAML exceeds 1 MiB.',emptyFile:'Select a YAML file or paste its contents.',
  providers:'Subscription server names',providersHelp:'If the administrator enabled export, download a JSON compatible with Mihomo Unified Generator: provider and node names only, no server addresses or passwords. In the builder use “Import nodes from running Mihomo” → “Upload .json”. This does not change Mihomo.',providersDownload:'Download node names JSON',providersDisabled:'Export is not enabled by the administrator',providersWorking:'Reading active Mihomo providers…',providersSuccess:'Names JSON saved. Upload it to Mihomo Builder and choose exclusions.',providersError:'Unable to read names: {code}. Check the local Mihomo API and its secret.',
  filterHeading:'🚫 Subscription server filtering (preview and apply)',filterHelp:'Experimental preview of loaded Mihomo node names and possible exclude-filter changes. Applying runs the canonical KAS importer after explicit confirmation; if config.yaml changed since the preview, the importer rejects it without changes. Removing a filter works even when excluded nodes are invisible in the API. Only supported HTTP providers can be edited; complex YAML must use the ordinary importer.',filterLoad:'Load providers and nodes',filterProviderLabel:'Provider:',filterPreview:'Preview filter for checked nodes',filterClear:'Preview removing filter',filterHint:'Checked means exclude. Previously excluded nodes may be absent from Mihomo API. Review an existing filter before replacing it.',filterNoProvider:'No supported HTTP providers',filterExisting:'Existing exclude-filter: {filter}',filterNoFilter:'not set',filterLoading:'Reading local data…',filterLoaded:'Providers loaded. Select exclusions.',filterNamesUnavailable:'Node names unavailable: {code}. You can clear the existing filter; exclusion selection requires refreshing the node list.',filterCannotLoad:'Cannot read data: {code}',filterNoNames:'No visible nodes (or already hidden by the active filter).',filterTooMany:'Showing first {count} nodes; full list is available via JSON export.',filterPreviewing:'Validating preview…',filterPreviewReady:'Preview ready. The change is not applied yet.',filterPreviewError:'Preview error: {code}',filterNothing:'Select at least one node.',filterProposed:'Previous: {before}\nProposed: {after}\nPreview only so far. Press “Apply shown change” to write it.',filterApply:'Apply shown change',filterApplyConfirm:'Apply the shown exclude-filter change through the canonical KAS importer? Mihomo might restart briefly. If config.yaml changed since the preview, the apply is rejected without changes.',filterApplying:'Applying through the canonical importer. Do not power off the router…',filterApplyDone:'The canonical importer completed successfully.',filterApplyReady:'Change applied by the canonical importer. Node list reloaded from the running Mihomo.',filterApplyNoChange:'The change already matches the current configuration; no import was started.',filterApplyError:'Could not start the apply: {code}',filterApplyFail:'The importer reported an error. The change may not be applied; check the actual state with Doctor/SSH.',
  doctor:'Doctor diagnostics',help:'Run the canonical Doctor on demand. This does not prove every client route.',run:'Run Doctor',copy:'Copy report',details:'Original command output',running:'Doctor is running…',finished:'Command finished; exit code: {exit}',failed:'Command did not complete successfully; exit code: {exit}; error: {code}',error:'Request failed: {code}',footer:'Do not claim rollback without checking the actual router state. Review diagnostics manually before sharing.',timestamp:'Time: {time}',notrun:'Doctor has not been run yet.'
 }
};
let lang=(navigator.language||'en').toLowerCase().startsWith('ru')?'ru':'en';
try{const s=localStorage.getItem('kas_lang');if(s==='ru'||s==='en')lang=s;}catch(_){}
let statusData=null,doctorData=null,busy=false,importData=null,submitting=false,pollTimer=null,importMessage='';
let exporting=false,providerMessage='';
let accessData=null,accessBusy=false,accessStatus='';
let filterInspect=null,filterNodes=null,filterStatus='',filterSelectedProvider='',filterLoading=false,filterBusy=false;
let filterPending=null,filterAwaitingApply=false;
const el=id=>document.getElementById(id);
const t=(key,params={})=>{
 const value=words[lang][key]??words.en[key]??key;
 return value.replace(/\{(\w+)\}/g,(_,k)=>String(params[k]??''));
};
const set=(id,value)=>{el(id).textContent=value;};
function draw(){
 document.documentElement.lang=lang;
 set('access-state',accessBusy?t('accessLoading'):accessStatus||(accessData?t(accessData.home_only?'accessOn':'accessOff'):''));
 el('access-home-only').disabled=accessBusy||!accessData;el('access-save').disabled=accessBusy||!accessData;
 for(const [id,key] of [['scope','scope'],['access-heading','accessHeading'],['access-label','accessHomeOnly'],['access-help','accessHelp'],['access-save','accessSave'],['status-heading','status'],['refresh','refresh'],['config-heading','config'],['config-help','configHelp'],['file-label','fileLabel'],['paste-label','pasteLabel'],['config-warning','warning'],['apply','apply'],['filter-heading','filterHeading'],['filter-help','filterHelp'],['filter-load','filterLoad'],['filter-provider-label','filterProviderLabel'],['filter-preview','filterPreview'],['filter-clear','filterClear'],['filter-apply','filterApply'],['filter-hint','filterHint'],['providers-heading','providers'],['providers-help','providersHelp'],['providers-download','providersDownload'],['doctor-heading','doctor'],['doctor-help','help'],['run','run'],['copy','copy'],['details-label','details'],['footer','footer']])set(id,t(key));
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
 set('filter-state',filterLoading?t('filterLoading'):filterStatus);
 el('filter-load').disabled=filterLoading||filterBusy;
 el('filter-preview').disabled=!filterInspect||!filterNodes||filterBusy||filterLoading||!filterSelectedProvider;
 el('filter-clear').disabled=!filterInspect||filterBusy||filterLoading||!filterSelectedProvider;
 el('filter-apply').disabled=!filterPending||filterBusy||filterLoading||runningImport;
 set('providers-state',exporting?t('providersWorking'):providerMessage);
 el('providers-download').disabled=exporting;
 set('doctor-state',busy?t('running'):doctorData?((doctorData.error_code||doctorData.exit_code!==0)?t('failed',{exit:doctorData.exit_code??'?',code:doctorData.error_code??'EXIT_NONZERO'}):t('finished',{exit:doctorData.exit_code}))+ ' — '+t('timestamp',{time:doctorData.timestamp}):t('notrun'));
 set('output',doctorData?.details||'');
 el('copy').disabled=!doctorData||!doctorData.details;el('run').disabled=busy||runningImport;
 el('ru').setAttribute('aria-pressed',String(lang==='ru'));el('en').setAttribute('aria-pressed',String(lang==='en'));
}
async function refreshAccess(){
 if(accessBusy)return;
 accessBusy=true;accessStatus='';draw();
 try{
  const response=await fetch('/api/access',{cache:'no-store'});
  const data=await response.json();
  if(!response.ok||typeof data.home_only!=='boolean')throw Error(data.error_code||'HTTP_'+response.status);
  accessData=data;el('access-home-only').checked=data.home_only;
 }catch(e){accessData=null;accessStatus=t('accessError',{code:e.message||'UNKNOWN'});}
 finally{accessBusy=false;draw();}
}
async function saveAccess(){
 if(accessBusy||!accessData)return;
 const homeOnly=el('access-home-only').checked;
 if(homeOnly===accessData.home_only)return;
 if(!window.confirm(t(homeOnly?'accessEnableConfirm':'accessDisableConfirm'))){el('access-home-only').checked=accessData.home_only;return;}
 accessBusy=true;accessStatus='';draw();
 try{
  const response=await fetch('/api/access',{method:'POST',cache:'no-store',headers:{'Content-Type':'application/json','X-KAS-Confirm':'access'},body:JSON.stringify({home_only:homeOnly})});
  const data=await response.json();
  if(!response.ok||typeof data.home_only!=='boolean')throw Error(data.error_code||'HTTP_'+response.status);
  accessData=data;el('access-home-only').checked=data.home_only;
 }catch(e){el('access-home-only').checked=accessData.home_only;accessStatus=t('accessError',{code:e.message||'UNKNOWN'});}
 finally{accessBusy=false;draw();}
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
 let wasRunning=false;
 if(importData)wasRunning=importData.state==='RUNNING';
 try{
  const resp=await fetch('/api/config/operation',{cache:'no-store'});
  if(!resp.ok)throw Error('HTTP '+resp.status);
  importData=await resp.json();
  importMessage='';
 }catch(e){importMessage=t('importError',{code:String(e)});}
 if(filterAwaitingApply&&importData&&importData.state!=='RUNNING'){
  // A filter apply finished: report its result honestly, then refresh the
  // SHA, filter lines and node list from the actual router state.
  const ok=importData.state==='OK';
  filterAwaitingApply=false;filterPending=null;set('filter-result','');
  if(filterInspect)await loadFilterEditor();
  filterStatus=ok?(filterNodes?t('filterApplyReady'):t('filterApplyDone')+' '+filterStatus):t('filterApplyFail');
 }
 draw();
 if(importData?.state==='RUNNING')schedulePoll();
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
el('refresh').addEventListener('click',()=>{refresh();refreshAccess();});
el('access-save').addEventListener('click',saveAccess);
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
// Read-only staged filter editor. Do not persist node names or raw provider JSON.
function renderFilterNodes(){
 // A fresh snapshot invalidates any previously previewed change.
 filterPending=null;
 const selector=el('filter-provider');
 const providers=(filterInspect?.providers||[]).filter(p=>p.http);
 selector.replaceChildren();
 for(const provider of providers){
  const o=document.createElement('option');o.value=provider.name;o.textContent=provider.name;selector.appendChild(o);
 }
 if(!providers.some(p=>p.name===filterSelectedProvider))filterSelectedProvider=providers[0]?.name||'';
 selector.value=filterSelectedProvider;selector.disabled=!filterSelectedProvider;
 const chosen=providers.find(p=>p.name===filterSelectedProvider);
 set('filter-existing',chosen?t('filterExisting',{filter:chosen.has_filter?chosen.existing_filter:t('filterNoFilter')}):t('filterNoProvider'));
 const list=el('filter-node-list');list.replaceChildren();
 const available=filterNodes?.providers?.[filterSelectedProvider]?.proxies||[];
 const names=[...new Set(available.map(p=>p.name).filter(x=>typeof x==='string'&&x))];
 for(const name of names.slice(0,400)){
  const label=document.createElement('label');label.style.display='block';
  const check=document.createElement('input');check.type='checkbox';check.value=name;
  label.appendChild(check);label.appendChild(document.createTextNode(' '+name));
  list.appendChild(label);
 }
 if(names.length===0){const tip=document.createElement('p');tip.textContent=t('filterNoNames');list.appendChild(tip);}
 if(names.length>400){const tip=document.createElement('p');tip.textContent=t('filterTooMany',{count:400});list.appendChild(tip);}
 draw();
}
async function readFilterJSON(url){
 const response=await fetch(url,{cache:'no-store'});
 if(!response.ok){
  let code='HTTP_'+response.status;
  try{const data=await response.json();code=data.error_code||code;}catch(_){}
  throw Error(code);
 }
 return response.json();
}
async function loadFilterEditor(){
 if(filterLoading)return;
 filterLoading=true;filterStatus='';filterPending=null;set('filter-result','');draw();
 try{
  // A names failure must not discard the successfully inspected config:
  // clearing needs only the provider name and the approved config SHA.
  const [inspect,nodes]=await Promise.allSettled([
   readFilterJSON('/api/filter/providers'),readFilterJSON('/api/providers/names')
  ]);
  if(inspect.status!=='fulfilled')throw inspect.reason;
  filterInspect=inspect.value;
  filterNodes=nodes.status==='fulfilled'?nodes.value:null;
  filterStatus=filterNodes?t('filterLoaded'):t('filterNamesUnavailable',{code:nodes.reason?.message||'UNKNOWN'});
  renderFilterNodes();
 }catch(e){filterInspect=null;filterNodes=null;filterSelectedProvider='';filterPending=null;filterStatus=t('filterCannotLoad',{code:e.message||'UNKNOWN'});el('filter-node-list').replaceChildren();el('filter-provider').replaceChildren();set('filter-existing','');set('filter-result','');}
 finally{filterLoading=false;draw();}
}
async function previewFilterChange(clear){
 if(!filterInspect||!filterSelectedProvider||filterBusy)return;
 const names=clear?[]:[...el('filter-node-list').querySelectorAll('input:checked')].map(el=>el.value);
 if(!clear&&!filterNodes)return;
 if(!clear&&!names.length){filterStatus=t('filterNothing');draw();return;}
 filterBusy=true;filterStatus=t('filterPreviewing');set('filter-result','');filterPending=null;draw();
 try{
  const response=await fetch('/api/filter/preview',{
   method:'POST',cache:'no-store',headers:{'Content-Type':'application/json','X-KAS-Confirm':'preview'},
   body:JSON.stringify({provider:filterSelectedProvider,names,clear,source_sha:filterInspect.source_sha})
  });
  const data=await response.json();
  if(!response.ok)throw Error(data.error_code||'HTTP_'+response.status);
  set('filter-result',t('filterProposed',{before:data.existing_filter||t('filterNoFilter'),after:data.proposed_filter||t('filterNoFilter')}));
  filterPending={provider:filterSelectedProvider,names,clear};
  filterStatus=t('filterPreviewReady');
 }catch(e){filterStatus=t('filterPreviewError',{code:e.message||'UNKNOWN'});}
 finally{filterBusy=false;draw();}
}
// Explicit, separately confirmed write through the canonical importer.
// The server re-verifies the source SHA and its importer owns the rest.
async function applyFilterChange(){
 if(!filterPending||filterBusy||importData?.state==='RUNNING')return;
 if(!window.confirm(t('filterApplyConfirm')))return;
 filterBusy=true;filterStatus=t('filterApplying');draw();
 try{
  const response=await fetch('/api/filter/apply',{
   method:'POST',cache:'no-store',headers:{'Content-Type':'application/json','X-KAS-Confirm':'apply'},
   body:JSON.stringify({provider:filterPending.provider,names:filterPending.names,clear:filterPending.clear,source_sha:filterInspect.source_sha})
  });
  if(response.status===200){
   const data=await response.json();
   if(data.applied===false){
    filterPending=null;filterStatus=t('filterApplyNoChange');set('filter-result','');draw();return;
   }
  }
  const data=await response.json();
  if(response.status!==202)throw Error(data.error_code||'HTTP_'+response.status);
  importData=data;importMessage='';filterAwaitingApply=true;
  schedulePoll();
 }catch(e){filterStatus=t('filterApplyError',{code:e.message||'UNKNOWN'});}
 finally{filterBusy=false;draw();}
}
el('filter-load').addEventListener('click',loadFilterEditor);
el('filter-provider').addEventListener('change',()=>{filterSelectedProvider=el('filter-provider').value;filterStatus='';set('filter-result','');renderFilterNodes();});
el('filter-preview').addEventListener('click',()=>previewFilterChange(false));
el('filter-clear').addEventListener('click',()=>previewFilterChange(true));
el('filter-apply').addEventListener('click',applyFilterChange);

el('apply').addEventListener('click',applyYAML);
el('providers-download').addEventListener('click',exportProviders);
el('copy').addEventListener('click',async()=>{if(!doctorData?.details)return;try{await navigator.clipboard.writeText(doctorData.details)}catch(_){}});
draw();refresh();refreshImport();refreshAccess();
