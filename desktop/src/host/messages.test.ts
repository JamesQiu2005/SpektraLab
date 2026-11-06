// @vitest-environment jsdom
import { afterEach, describe, expect, it } from 'vitest';
import { setLanguage } from '../i18n';
import { hostMessage } from './messages';

afterEach(() => setLanguage('english'));

describe('hostMessage', () => {
  it('returns the host text unchanged in English', () => {
    setLanguage('english');
    expect(hostMessage('camera profile was not matched uniquely')).toBe('camera profile was not matched uniquely');
    expect(hostMessage('not found: D:/a.NEF')).toBe('not found: D:/a.NEF');
  });
  it('translates known texts in Chinese and keeps the detail of prefixed ones', () => {
    setLanguage('simplifiedChinese');
    expect(hostMessage('camera profile was not matched uniquely')).toBe('没有唯一匹配到相机配置文件');
    expect(hostMessage('not found: D:/a.NEF')).toBe('找不到文件：D:/a.NEF');
    expect(hostMessage('lens correction: lens profile was not matched uniquely')).toBe('镜头校正：没有唯一匹配到镜头配置文件');
  });
  it('passes an unknown text through, so no host message is hidden', () => {
    setLanguage('simplifiedChinese');
    expect(hostMessage('TIFF strip outside file')).toBe('TIFF strip outside file');
    expect(hostMessage('')).toBe('');
  });
  it('never meets Object.prototype: a file named like a built-in property is a file name', () => {
    setLanguage('simplifiedChinese');
    for (const name of ['constructor', 'toString', '__proto__', 'hasOwnProperty', 'valueOf'])
      expect(hostMessage(`not found: ${name}`)).toBe(`找不到文件：${name}`);
    expect(hostMessage('constructor')).toBe('constructor');
  });
});
