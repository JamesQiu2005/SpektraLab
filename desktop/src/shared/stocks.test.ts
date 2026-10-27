import {it,expect} from 'vitest';
import {StockCatalog,selectedFilm,selectedPaper} from './stocks';
import {FILM_PARAMS_DEFAULT,fullDelta,effectiveEDR} from './params';
const catalog=new StockCatalog([
  {id:'kodak_portra_400',name:'Portra',stage:'filming',use:'still',type:'negative',targetPrint:'kodak_supra_endura',hasPreviewLUT:false},
  {id:'kodak_ektachrome_100',name:'Slide',stage:'filming',use:'still',type:'positive',hasPreviewLUT:false},
  {id:'kodak_tri_x_400',name:'Tri-X',stage:'filming',use:'still',type:'negative',monochrome:true,targetPrint:'ilford_multigrade_iv_rc',hasPreviewLUT:false},
  {id:'kodak_supra_endura',name:'Colour paper',stage:'printing',use:'still',hasPreviewLUT:false},
  {id:'ilford_multigrade_iv_rc',name:'Silver paper',stage:'printing',use:'still',monochrome:true,hasPreviewLUT:false},
]);
it('separates the original Black & White group and permits only compatible papers',()=>{
  expect(catalog.filmGroups().map(g=>[g.title,g.films.map(s=>s.id)])).toEqual([
    ['Positive',['kodak_ektachrome_100']],['Negative',['kodak_portra_400']],['Black & White',['kodak_tri_x_400']]]);
  expect(catalog.canPrint('kodak_tri_x_400','ilford_multigrade_iv_rc')).toBe(true);
  expect(catalog.canPrint('kodak_tri_x_400','kodak_supra_endura')).toBe(false);
  expect(catalog.canPrint('kodak_portra_400','ilford_multigrade_iv_rc')).toBe(false);
  expect(catalog.canPrint('unknown','unknown')).toBe(true);
});
it('uses the original neutral silver pack, single-layer grain and per-film amounts without EDR',()=>{
  for(const [film,grain] of [['kodak_tri_x_400',1.7],['kodak_tmax_100',.74],['fujifilm_neopan_acros_100_ii',.64],['ilford_hp5_plus_400',1.49]] as const){
    const p={...FILM_PARAMS_DEFAULT,filmStock:film,printStock:'ilford_multigrade_iv_rc',extendedDynamicRange:true,effects:{...FILM_PARAMS_DEFAULT.effects,grain:1,grainLayered:true}};
    const d=fullDelta(p);expect(d.grain_amount).toBe(grain);expect(d.grain_sublayers_active).toBe(false);
    expect([d.c_filter_neutral,d.m_filter_neutral,d.y_filter_neutral]).toEqual([0,0,68]);expect(effectiveEDR(p)).toBe(false);
  }
  const colour=fullDelta(FILM_PARAMS_DEFAULT);expect(colour.y_filter_neutral).toBeUndefined();
  expect(colour.grain_amount).toBe(FILM_PARAMS_DEFAULT.effects.grain);
});
it('chooses declared papers, rejects incompatible paper selections and scans positive films',()=>{
  const bw=selectedFilm(FILM_PARAMS_DEFAULT,'kodak_tri_x_400',catalog);
  expect(bw.printStock).toBe('ilford_multigrade_iv_rc');
  expect(selectedPaper(bw,'kodak_supra_endura',catalog)).toBe(bw);
  const colour=selectedFilm(bw,'kodak_portra_400',catalog);expect(colour.printStock).toBe('kodak_supra_endura');
  expect(selectedPaper(colour,'ilford_multigrade_iv_rc',catalog)).toBe(colour);
  const slide=selectedFilm(colour,'kodak_ektachrome_100',catalog);
  expect(slide.scanFilm).toBe(true);expect(slide.printStock).toBe(colour.printStock);
  expect(selectedPaper(slide,'kodak_supra_endura',catalog)).toBe(slide);
});
