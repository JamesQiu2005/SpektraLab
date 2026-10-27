// A real camera/embedded preview while a hole is reframed, as PairDragPreview
// on the Mac. It never replaces the Vulkan-developed print/export pixels.
import {useEffect,useRef,useState} from 'react';
import type {PairHole} from '@shared/pairs';
import {type Size,type Geometry,GEOMETRY_DEFAULT,outputSize} from '@shared/geometry';
import {ADJUSTMENTS_DEFAULT} from '@shared/adjustments';
import {type Placement,placedRect} from '@shared/pairPlacement';
import type {RgbaImage} from '../host/client';
import {host} from '../host/client';
import {GLRenderer} from './glRenderer';
let framingRenderer:GLRenderer|null=null;
function framed(image:RgbaImage,g:Geometry):RgbaImage {
  framingRenderer??=new GLRenderer(new OffscreenCanvas(1,1));
  const target=outputSize(g,image),scale=Math.min(1,2048/Math.max(target.width,target.height));
  const width=Math.max(1,Math.round(target.width*scale)),height=Math.max(1,Math.round(target.height*scale));
  framingRenderer.setImage(image);
  const data=framingRenderer.renderOutput({viewport:{width,height},offset:{x:0,y:0},outSize:{width,height},sourceSize:image,
    display:g,editingCrop:null,adjustments:ADJUSTMENTS_DEFAULT,compare:0,split:.5,surround:0},width,height);
  if(!data)throw new Error('Could not frame the camera preview');return {width,height,data,colorSpace:image.colorSpace};
}
export interface PairPicture {path:string;geometryKey:string;bitmap:ImageBitmap;source:Size}
export const pictureKey=(hole:PairHole)=>JSON.stringify([hole.geometry,hole.placement.quarterTurns]);
export function framePairCamera(image:RgbaImage,hole:PairHole):RgbaImage {
  return framed(framed(image,hole.geometry),{...GEOMETRY_DEFAULT,quarterTurns:hole.placement.quarterTurns});
}
export function usePairPicture(hole:PairHole|null,enabled:boolean){
  const [picture,setPicture]=useState<PairPicture|null>(null),[error,setError]=useState<string|null>(null);
  const path=hole?.path,key=hole?pictureKey(hole):'';
  useEffect(()=>{
    let cancelled=false,bitmap:ImageBitmap|null=null;setPicture(null);setError(null);
    if(!enabled||!hole)return;
    void (async()=>{
      try{
        const [probe,image]=await Promise.all([host().probe(hole.path),host().thumbnail(hole.path,2048)]);
        if(cancelled)return;
        // Owner crop/straighten/turn/flips, then the placement's quarter turn.
        const shown=framePairCamera(image,hole);
        bitmap=await createImageBitmap(new ImageData(new Uint8ClampedArray(shown.data),shown.width,shown.height));
        if(cancelled){bitmap.close();return;}
        setPicture({path:hole.path,geometryKey:key,bitmap,source:outputSize(hole.geometry,probe)});
      }catch(e){if(!cancelled)setError(e instanceof Error?e.message:String(e));}
    })();
    return ()=>{cancelled=true;bitmap?.close();};
    // Pixel intent, not metadata such as cached readings or a print trim.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  },[enabled,path,key]);
  return {picture,error};
}
export function PairPictureCanvas({picture,placement,aspect,width,height,dpr}:{picture:PairPicture;placement:Placement;aspect:number;width:number;height:number;dpr:number}){
  const ref=useRef<HTMLCanvasElement>(null);
  useEffect(()=>{
    const canvas=ref.current;if(!canvas)return;
    const scale=Math.min(dpr,2048/Math.max(width,height));
    canvas.width=Math.max(1,Math.round(width*scale));canvas.height=Math.max(1,Math.round(height*scale));
    const r=placedRect(placement,picture.bitmap,aspect),ctx=canvas.getContext('2d');if(!ctx)return;
    ctx.clearRect(0,0,canvas.width,canvas.height);ctx.imageSmoothingEnabled=true;
    ctx.drawImage(picture.bitmap,r.x,r.y,r.width,r.height,0,0,canvas.width,canvas.height);
  },[picture,placement,aspect,width,height,dpr]);
  return <canvas ref={ref} style={{width:'100%',height:'100%'}} data-testid="pair-camera-preview"/>;
}
