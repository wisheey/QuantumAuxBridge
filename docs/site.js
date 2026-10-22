'use strict';
const names=['Vocal','Guitar','Keys','Bass','Drums'];
const levels=[0,-12,-8,-16,-22];
const root=document.getElementById('demo');
names.forEach((name,i)=>{
 const card=document.createElement('div');card.className='fader-card';
 const out=document.createElement('output');out.id=`level-${i}`;
 const track=document.createElement('div');track.className='track';
 const rail=document.createElement('div');rail.className='rail';
 const fill=document.createElement('div');fill.className='fill';
 const cap=document.createElement('div');cap.className='cap';
 const unity=document.createElement('span');unity.className='unity';unity.textContent='0 dB';
 rail.append(fill,cap,unity);
 const input=document.createElement('input');input.className='demo-slider';input.type='range';input.min=-50;input.max=10;input.step=.5;input.value=levels[i];input.setAttribute('aria-label',`${name} preview send level`);input.setAttribute('aria-describedby',out.id);
 const update=()=>{const value=Number(input.value);out.value=`${value>0?'+':''}${value} dB`;rail.style.setProperty('--p',`${(value+50)/60*100}%`);input.setAttribute('aria-valuetext',out.value)};
 input.addEventListener('input',update);update();track.append(rail,input);
 const label=document.createElement('div');label.className='channel';const n=document.createElement('small');n.textContent=`CH 0${i+1}`;label.append(n,document.createTextNode(name));card.append(out,track,label);root.append(card);
});
