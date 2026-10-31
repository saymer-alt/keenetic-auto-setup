'use strict';
// Presentation only: switching sections never sends API requests or resets forms.
(()=>{
 const names=['overview','subscriptions','configuration','diagnostics','settings'];
 const nav=document.getElementById('view-nav');
 function show(name){
  if(!names.includes(name))name='overview';
  for(const key of names){
   document.getElementById('view-'+key).hidden=key!==name;
   const button=document.getElementById('nav-'+key);
   if(key===name)button.setAttribute('aria-current','page');else button.removeAttribute('aria-current');
  }
  document.documentElement.dataset.view=name;
  window.kasDraw?.();
 }
 for(const button of document.querySelectorAll('[data-view]'))button.addEventListener('click',event=>{
  event.preventDefault();
  show(button.dataset.view);
  document.getElementById('content').focus({preventScroll:true});
 });
 nav.addEventListener('keydown',event=>{
  const current=names.indexOf(event.target.dataset.view);
  if(current<0)return;
  let next=current;
  if(event.key==='ArrowRight'||event.key==='ArrowDown')next=(current+1)%names.length;
  else if(event.key==='ArrowLeft'||event.key==='ArrowUp')next=(current+names.length-1)%names.length;
  else if(event.key==='Home')next=0;
  else if(event.key==='End')next=names.length-1;
  else return;
  event.preventDefault();show(names[next]);document.getElementById('nav-'+names[next]).focus();
 });
 show('overview');
})();
