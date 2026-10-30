'use strict';
// Run before CSS to apply a browser-local preference without a light flash.
(()=>{
 const valid=value=>['auto','light','dark'].includes(value);
 let mode='auto';
 try{const saved=localStorage.getItem('kas_theme');if(valid(saved))mode=saved;}catch(_){}
 const apply=()=>document.documentElement.setAttribute('data-theme',mode);
 apply();
 window.kasTheme={get:()=>mode,set:value=>{
  mode=valid(value)?value:'auto';apply();
  try{localStorage.setItem('kas_theme',mode);}catch(_){}
 }};
})();
