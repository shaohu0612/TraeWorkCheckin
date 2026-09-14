const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const net = require('net');
const https = require('https');
const dns = require('dns');
const os = require('os');
const { execFile, execFileSync, spawn } = require('child_process');

/**
 * TraeWorkCheckin 每日自动签到核心引擎
 * -----------------------------------------------------------
 * 1. 开机网络异步就绪与自愈探测：轻量探活，开机未联网时自愈等待，恢复后秒级唤醒；
 * 2. 零内存常驻与极速资源回收：完成日志与通知后立即销毁退出，内存彻底归零；
 * 3. 三重兜底保障机制：运行时重试 + 30分钟临时计划任务 (TraeWorkCheckin_Retry) + 失效弹窗；
 * 4. 严格防风控设计：先查后签秒级跳过、开机随机抖动 Jitter、官方设备指纹 100% 拟真；
 * 5. 任务命名空间隔离：计划任务与重试任务强绑定 TraeWork 前缀，杜绝与同类工具冲突。
 */

// 全局常量配置
const STATUS_URL = 'https://api.trae.cn/trae/api/v2/ug/checkin_credits/status';
const CLAIM_URL = 'https://api.trae.cn/trae/api/v2/ug/checkin_credits/claim';
const RETRY_TASK_NAME = 'TraeWorkCheckin_Retry'; // 严格包含 TraeWork 字样，避免与其他签到任务冲突

// 凭据解密算法底层常量
const HP = 16, q8_AES128 = 16, WP = HP, rh = 64, Rv = 32, VP = 64, Em = 6;
const ure = Uint8Array.from([82,9,106,213,48,54,165,56,191,64,163,158,129,243,215,251,124,227,57,130,155,47,255,135,52,142,67,68,196,222,233,203,84,123,148,50,166,194,35,61,238,76,149,11,66,250,195,78,8,46,161,102,40,217,36,178,118,91,162,73,109,139,209,37]);
const dre = Uint8Array.from([31,221,168,51,136,7,199,49,177,18,16,89,39,128,236,95,96,81,127,169,25,181,74,13,45,229,122,159,147,201,156,239,160,224,59,77,174,42,245,176,200,235,187,60,131,83,153,97,23,43,4,126,186,119,214,38,225,105,20,99,85,33,12,125]);

/**
 * 延时辅助函数
 * @param {number} ms 毫秒数
 */
function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

/**
 * 获取本地日志文件完整路径
 */
function getLogPath() {
  const logDir = path.join(__dirname, 'log');
  try {
    if (!fs.existsSync(logDir)) {
      fs.mkdirSync(logDir, { recursive: true });
    }
    return path.join(logDir, 'checkin.log');
  } catch (e) {
    return path.join(__dirname, 'checkin.log');
  }
}

/**
 * 结构化写入运行日志，并向控制台安全打印
 * @param {string} msg 日志内容
 * @param {string} level 日志级别 (INFO / SUCCESS / SKIP / WAIT / RETRY / FALLBACK / WARN / ERROR / START / FINISH)
 */
function writeLog(msg, level = 'INFO') {
  const now = new Date();
  const pad = n => String(n).padStart(2, '0');
  const timeStr = `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())} ${pad(now.getHours())}:${pad(now.getMinutes())}:${pad(now.getSeconds())}`;
  const logLine = `[${timeStr}] [${level}] ${msg}\n`;

  try {
    fs.appendFileSync(getLogPath(), logLine, 'utf8');
  } catch (e) {
    // 忽略写入日志异常，确保主业务不中断
  }

  console.log(`[${level}] ${msg}`);
}

/**
 * 用户 ID 脱敏显示处理，保护隐私安全
 * @param {string|number} uid 原始用户ID
 */
function maskUserId(uid) {
  if (!uid) return '未知';
  const str = String(uid).trim();
  if (str.length <= 6) return '******';
  return `${str.slice(0, 4)}****${str.slice(-2)}`;
}

// ---- 开机网络异步就绪与自愈探测 ---------------------------------------

/**
 * 基于原生 TCP Socket 超轻量探测端口连通性 (毫秒级，0开销)
 * @param {string} host 目标主机或 IP
 * @param {number} port 端口
 * @param {number} timeoutMs 超时时间(毫秒)
 */
function checkSocket(host, port, timeoutMs = 1500) {
  return new Promise(resolve => {
    try {
      const socket = net.createConnection({ host, port, timeout: timeoutMs }, () => {
        socket.destroy();
        resolve(true);
      });
      socket.on('error', () => { socket.destroy(); resolve(false); });
      socket.on('timeout', () => { socket.destroy(); resolve(false); });
    } catch {
      resolve(false);
    }
  });
}

/**
 * 综合检测互联网连通性
 */
async function isOnline() {
  const dnsTargets = [
    ['223.5.5.5', 53],   // 阿里公共 DNS
    ['119.29.29.29', 53], // 腾讯公共 DNS
    ['1.1.1.1', 53]       // Cloudflare DNS
  ];

  for (const [host, port] of dnsTargets) {
    if (await checkSocket(host, port, 1500)) {
      return true;
    }
  }
  return false;
}

/**
 * 开机网络自愈等待队列：
 * 开机进入 Windows 桌面时网卡与 Wi-Fi 往往尚未连接就绪。
 * 本函数循环低开销探测网络状态，网络一旦通畅立即唤醒继续，超时则优雅触发兜底。
 * @param {number} maxWaitSeconds 最长等待秒数 (默认 300 秒)
 * @param {number} intervalSeconds 探测间隔秒数 (默认 5 秒)
 */
async function waitForNetwork(maxWaitSeconds = 300, intervalSeconds = 5) {
  if (await isOnline()) {
    return true;
  }

  writeLog(`开机网络尚未就绪，正在等待网络恢复连接（最长等待 ${maxWaitSeconds} 秒）...`, 'WAIT');
  const startTime = Date.now();

  while ((Date.now() - startTime) < maxWaitSeconds * 1000) {
    await sleep(intervalSeconds * 1000);
    if (await isOnline()) {
      const elapsed = Math.round((Date.now() - startTime) / 1000);
      writeLog(`网络已成功恢复连通！（等待耗时 ${elapsed} 秒），立即启动签到流程。`, 'SUCCESS');
      return true;
    }
  }

  writeLog(`等待网络连通超时（超过 ${maxWaitSeconds} 秒），暂不执行网络请求。`, 'WARN');
  return false;
}

// ---- Windows 任务计划兜底机制 (三重保障之第二道防线) -----------------

/**
 * 注册单次延时重试计划任务 (确保任务名包含 TraeWork，杜绝命名冲突)
 */
function registerRetryTask() {
  if (process.platform !== 'win32') {
    return;
  }
  try {
    const now = new Date(Date.now() + 30 * 60 * 1000); // 30 分钟后
    const pad = n => String(n).padStart(2, '0');
    const retryTime = `${pad(now.getHours())}:${pad(now.getMinutes())}`;
    const cmdPath = path.join(__dirname, 'run_traework_checkin.cmd');

    const psCmd = `schtasks /Create /TN '${RETRY_TASK_NAME}' /SC ONCE /ST ${retryTime} /TR '\\"${cmdPath}\\" --silent' /F`;
    try {
      execFileSync('powershell', ['-NoProfile', '-WindowStyle', 'Hidden', '-Command', psCmd], { stdio: 'ignore', timeout: 5000 });
      writeLog(`已激活第二道兜底保障：将于 ${retryTime} 自动执行重试任务（任务名: ${RETRY_TASK_NAME}）。`, 'FALLBACK');
    } catch (cmdErr) {
      writeLog(`注册临时重试计划任务失败: ${cmdErr.message}`, 'WARN');
    }
  } catch (e) {
    writeLog(`注册临时重试计划任务异常: ${e.message}`, 'WARN');
  }
}

/**
 * 签到成功或已完成签到后，自动自愈注销当天的临时兜底任务，不留系统残留
 */
function cleanRetryTask() {
  if (process.platform !== 'win32') {
    return;
  }
  try {
    const psCmd = `schtasks /Delete /TN '${RETRY_TASK_NAME}' /F`;
    try {
      execFileSync('powershell', ['-NoProfile', '-WindowStyle', 'Hidden', '-Command', psCmd], { stdio: 'ignore', timeout: 3000 });
    } catch {}
  } catch (e) {
    // 忽略清理异常
  }
}

// ---- 原生桌面通知系统 ------------------------------------------------

/**
 * 跨平台弹出原生桌面系统通知（Windows Toast/托盘气泡、macOS 通知、Linux notify-send）
 * 采用进程分离模式，确保主程序可以毫秒级退出销毁
 * @param {string} title 通知标题
 * @param {string} message 通知正文
 */
function showNotification(title, message) {
  try {
    const cleanTitle = String(title).replace(/["`$]/g, '').replace(/\r?\n/g, ' ');
    const cleanMsg = String(message).replace(/["`$]/g, '').replace(/\r?\n/g, ' ');

    if (process.platform === 'win32') {
      const psCommand = `
        try {
          [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] > $null
          $template = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
          $textNodes = $template.GetElementsByTagName("text")
          $textNodes.Item(0).AppendChild($template.CreateTextNode("${cleanTitle}")) > $null
          $textNodes.Item(1).AppendChild($template.CreateTextNode("${cleanMsg}")) > $null
          $notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("TraeWorkCheckin")
          $notification = [Windows.UI.Notifications.ToastNotification]::new($template)
          $notifier.Show($notification)
        } catch {
          Add-Type -AssemblyName System.Windows.Forms
          $n = New-Object System.Windows.Forms.NotifyIcon
          $n.Icon = [System.Drawing.SystemIcons]::Information
          $n.BalloonTipTitle = "${cleanTitle}"
          $n.BalloonTipText = "${cleanMsg}"
          $n.Visible = $true
          $n.ShowBalloonTip(4000)
          Start-Sleep -Seconds 1
          $n.Dispose()
        }
      `;

      const child = spawn('powershell', ['-NoProfile', '-WindowStyle', 'Hidden', '-Command', psCommand], {
        detached: true,
        stdio: 'ignore'
      });
      child.unref();
    } else if (process.platform === 'darwin') {
      const child = spawn('osascript', ['-e', `display notification "${cleanMsg}" with title "${cleanTitle}"`], {
        detached: true,
        stdio: 'ignore'
      });
      child.unref();
    } else if (process.platform === 'linux') {
      const child = spawn('notify-send', [cleanTitle, cleanMsg], {
        detached: true,
        stdio: 'ignore'
      });
      child.unref();
    }
  } catch (e) {
    // 忽略通知异常，不影响核心签到业务
  }
}

// ---- 凭据提取与 WebCrypto AES 解密 ----------------------------------

/**
 * 兼容不同 Node.js / Electron 版本的 WebCrypto Subtle 接口获取
 */
function getSubtleCrypto() {
  if (typeof crypto !== 'undefined' && crypto.subtle) return crypto.subtle;
  if (typeof crypto !== 'undefined' && crypto.webcrypto && crypto.webcrypto.subtle) return crypto.webcrypto.subtle;
  if (typeof globalThis !== 'undefined' && globalThis.crypto && globalThis.crypto.subtle) return globalThis.crypto.subtle;
  return null;
}

async function sha512(data) {
  const subtle = getSubtleCrypto();
  if (!subtle) {
    throw new Error('当前环境缺少 WebCrypto subtle 模块支持，请确保使用 Node.js 18+ 或使用内置 Trae 运行时。');
  }
  const h = await subtle.digest('SHA-512', data);
  return new Uint8Array(h);
}

function xorArrays(a, b, n) {
  const r = new Uint8Array(n);
  for (let i = 0; i < n; i++) r[i] = a[i] ^ b[i];
  return r;
}

/**
 * 解密 storage.json 中的凭据信息 (AES-128-CBC)
 */
async function decrypt(b64) {
  const subtle = getSubtleCrypto();
  if (!subtle) {
    throw new Error('当前环境缺少 WebCrypto subtle 模块支持，请确保使用 Node.js 18+ 或使用内置 Trae 运行时。');
  }
  const t = new Uint8Array(Buffer.from(b64, 'base64'));
  const key = t.slice(Em, Em + Rv);
  const sha = await sha512(key);
  const xor = xorArrays(ure, dre, VP);
  const comb = new Uint8Array(rh + VP);
  comb.set(sha, 0);
  comb.set(xor, rh);
  const hash = await sha512(comb);
  const aesKey = hash.slice(0, q8_AES128);
  const iv = hash.slice(q8_AES128, q8_AES128 + WP);
  const ct = t.slice(Rv + Em);
  const ck = await subtle.importKey('raw', aesKey, { name: 'AES-CBC' }, false, ['decrypt']);
  const dec = new Uint8Array(await subtle.decrypt({ name: 'AES-CBC', iv }, ck, ct));
  return new TextDecoder().decode(dec.slice(rh));
}

/**
 * 获取各操作系统的应用配置根目录
 */
function getBaseConfigDir() {
  if (process.platform === 'win32') {
    return process.env.APPDATA || (process.env.USERPROFILE ? path.join(process.env.USERPROFILE, 'AppData', 'Roaming') : null);
  } else if (process.platform === 'darwin') {
    return process.env.HOME ? path.join(process.env.HOME, 'Library', 'Application Support') : null;
  } else {
    return process.env.XDG_CONFIG_HOME || (process.env.HOME ? path.join(process.env.HOME, '.config') : null);
  }
}

/**
 * 自动动态扫描并定位最活跃的有效 storage.json 路径
 */
function findStorageFile() {
  const baseDir = getBaseConfigDir();
  if (!baseDir) {
    throw new Error('未检测到用户配置目录环境变量（APPDATA 或 HOME）');
  }

  let candidateDirs = [];
  try {
    if (fs.existsSync(baseDir)) {
      const entries = fs.readdirSync(baseDir, { withFileTypes: true });
      candidateDirs = entries
        .filter(e => e.isDirectory() && e.name.toLowerCase().includes('trae'))
        .map(e => e.name);
    }
  } catch (e) {
    candidateDirs = [];
  }

  // 兜底常见官方客户端目录
  const defaultDirs = ['Trae CN', 'TRAE SOLO CN', 'Trae', 'Trae%20CN', 'TraeCode CN', 'TraeCode'];
  for (const d of defaultDirs) {
    if (!candidateDirs.includes(d)) candidateDirs.push(d);
  }

  const candidates = [];

  for (const dir of candidateDirs) {
    const filePath = path.join(baseDir, dir, 'User', 'globalStorage', 'storage.json');
    if (fs.existsSync(filePath)) {
      try {
        const content = fs.readFileSync(filePath, 'utf8');
        const data = JSON.parse(content);
        if (data['iCubeAuthInfo://icube.cloudide']) {
          const stats = fs.statSync(filePath);
          candidates.push({ dirName: dir, path: filePath, data, mtime: stats.mtimeMs });
        }
      } catch (e) {
        // 忽略无法解析或损坏的文件
      }
    }
  }

  if (candidates.length === 0) {
    throw new Error(
      `未在计算机中检测到任何有效的 Trae 登录凭据。\n` +
      `已扫描目录：\n` +
      candidateDirs.map(d => `  - ${path.join(baseDir, d)}`).join('\n') +
      `\n请先打开并登录 Trae / TraeWork 桌面端客户端后再运行本程序。`
    );
  }

  // 按文件最后修改时间倒序排列，优先选用最新活跃的有效凭据
  candidates.sort((a, b) => b.mtime - a.mtime);
  return candidates[0];
}

// ---- 网络通信与防风控重试交互 ---------------------------------------

// 火山引擎官方全国 CDN 优质节点池 (备用保底，防代理劫持)
const TRAE_CDN_FALLBACK_IPS = [
  '123.129.199.131',
  '123.129.199.132',
  '123.129.199.133',
  '39.91.164.180',
  '139.227.230.46',
  '218.98.46.65',
  '112.87.86.31'
];

let cachedDirectCdnIp = null;

/**
 * 通过 DNS-over-HTTPS (DoH) 获取真实 CDN IP (不受本地 Fake IP 影响)
 * @param {string} domain 目标域名
 */
function resolveRealIpViaDoh(domain = 'api.trae.cn') {
  return new Promise((resolve) => {
    const reqOptions = {
      hostname: '223.5.5.5', // 阿里公共 DNS 节点，通过直接 IP 通信穿透本地代理假 IP
      port: 443,
      path: `/resolve?name=${encodeURIComponent(domain)}&type=A`,
      method: 'GET',
      headers: { 'Host': 'dns.alidns.com' },
      servername: 'dns.alidns.com',
      timeout: 5000
    };

    const req = https.request(reqOptions, (res) => {
      let rawData = '';
      res.on('data', chunk => rawData += chunk);
      res.on('end', () => {
        try {
          const json = JSON.parse(rawData);
          const ips = (json.Answer || [])
            .filter(a => a.type === 1 && a.data && !a.data.startsWith('127.'))
            .map(a => a.data);
          if (ips.length > 0) {
            resolve(ips[Math.floor(Math.random() * ips.length)]);
            return;
          }
        } catch {}
        const fallback = TRAE_CDN_FALLBACK_IPS[Math.floor(Math.random() * TRAE_CDN_FALLBACK_IPS.length)];
        resolve(fallback);
      });
    });

    req.on('error', () => {
      const fallback = TRAE_CDN_FALLBACK_IPS[Math.floor(Math.random() * TRAE_CDN_FALLBACK_IPS.length)];
      resolve(fallback);
    });

    req.on('timeout', () => {
      req.destroy();
      const fallback = TRAE_CDN_FALLBACK_IPS[Math.floor(Math.random() * TRAE_CDN_FALLBACK_IPS.length)];
      resolve(fallback);
    });

    req.end();
  });
}

/**
 * 检测目标域名是否被系统代理劫持为 Fake IP (127.x.x.x)
 * @param {string} hostname 主机名
 */
function checkIsFakeIp(hostname = 'api.trae.cn') {
  return new Promise((resolve) => {
    dns.lookup(hostname, (err, address) => {
      if (err) {
        resolve({ isFake: true, ip: null, reason: err.message });
      } else if (address && address.startsWith('127.')) {
        resolve({ isFake: true, ip: address, reason: '检测到代理软件虚拟回环 Fake IP 劫持' });
      } else {
        resolve({ isFake: false, ip: address });
      }
    });
  });
}

/**
 * 底层高容错 HTTPS 请求封装器 (支持指定直连 IP 与 TLS SNI 证书严格校验)
 * @param {string} urlStr 目标请求 URL
 * @param {object} options 请求配置参数
 * @param {string|null} directIp 目标直连 IP
 */
function requestHttp(urlStr, options = {}, directIp = null) {
  return new Promise((resolve, reject) => {
    const parsedUrl = new URL(urlStr);
    const hostname = directIp || parsedUrl.hostname;
    const reqHeaders = { ...options.headers };

    if (directIp) {
      reqHeaders['Host'] = parsedUrl.hostname;
    }

    const reqOptions = {
      hostname,
      port: parsedUrl.port || 443,
      path: parsedUrl.pathname + parsedUrl.search,
      method: options.method || 'GET',
      headers: reqHeaders,
      servername: parsedUrl.hostname, // RFC 6066 SNI 扩展，严格保证 TLS 证书合法性
      timeout: options.timeout || 30000 // 保持原有 30 秒超时标准设置
    };

    const req = https.request(reqOptions, (res) => {
      let responseText = '';
      res.on('data', chunk => responseText += chunk);
      res.on('end', () => {
        let json = null;
        try {
          json = JSON.parse(responseText);
        } catch {
          // 非 JSON 响应保持为 null
        }
        resolve({
          status: res.statusCode,
          headers: res.headers,
          data: json,
          text: responseText
        });
      });
    });

    req.on('timeout', () => {
      req.destroy(new Error('网络请求超时 (30000ms)'));
    });

    req.on('error', (err) => {
      reject(err);
    });

    if (options.body) {
      const bodyStr = typeof options.body === 'string' ? options.body : JSON.stringify(options.body);
      req.write(bodyStr);
    }
    req.end();
  });
}

/**
 * 发送带指数退避与随机抖动重试机制的 HTTP 请求 (严格防风控、抗限流与免疫 Fake IP)
 */
async function fetchWithRetry(url, options, maxRetries = 8) {
  let lastError = null;
  let attempt = 1;
  let throttleAttempt = 0;
  const maxThrottleRetries = 5; // 官方早高峰 9074 限流最大独立重试次数

  // 1. 默认优先走系统原生网络/代理通道（与客户端保持相同链路），故障时按需降级至官方 CDN 节点
  let useDirectIp = cachedDirectCdnIp || null;

  while (attempt <= maxRetries) {
    try {
      const res = await requestHttp(url, options, useDirectIp);

      if (res.status === 401) {
        throw new Error('HTTP 401: 登录凭据 token 已失效，请在 Trae 客户端重新登录。');
      }

      if (res.status === 429 || res.status >= 500) {
        throw new Error(`HTTP 状态码异常: ${res.status}`);
      }

      const data = res.data;
      if (!data) {
        throw new Error(`服务器未返回合法 JSON 响应: ${res.text ? res.text.slice(0, 100) : '空内容'}`);
      }

      // 官方服务端繁忙/限流 (Code 9074) 处理：
      // 不消耗常规网络重试次数，适当拉大退避时间 (25~45秒) 避开开机早高峰拥堵
      if (data.code === 9074) {
        if (throttleAttempt < maxThrottleRetries) {
          throttleAttempt++;
          const delaySec = Math.floor(Math.random() * 20) + 25; // 随机 25~45 秒浮动退避
          writeLog(`官方服务器繁忙限流 (Code 9074: ${data.message || '参与用户过多'})，触发智能退避（不消耗常规网络重试次数），将在 ${delaySec} 秒后进行第 ${throttleAttempt}/${maxThrottleRetries} 次限流重试...`, 'RETRY');
          await sleep(delaySec * 1000);
          continue;
        }
      }

      return data;
    } catch (err) {
      lastError = err;
      if (err.message && err.message.includes('HTTP 401')) {
        throw err; // 鉴权失效直接向上抛出，不再重试
      }

      // 若发生网络异常且尚未启用直连 IP（或错误信息包含 127. 虚拟地址），立即无缝切换为官方 CDN 直连
      if (!useDirectIp || (err.message && err.message.includes('127.'))) {
        writeLog(`检测到网络链路异常 (${err.message})，自动切换至火山引擎官方 CDN 直连节点进行故障降级重试...`, 'WARN');
        cachedDirectCdnIp = await resolveRealIpViaDoh('api.trae.cn');
        useDirectIp = cachedDirectCdnIp;
        writeLog(`已自动接入火山引擎官方直连节点: ${useDirectIp} (SNI 证书保护)`, 'SUCCESS');
      }

      if (attempt < maxRetries) {
        const delaySec = Math.floor(Math.random() * 6) + attempt * 4; // 动态递增退避
        writeLog(`网络连接抖动 (${err.message})，将在 ${delaySec} 秒后进行第 ${attempt}/${maxRetries} 次重试...`, 'RETRY');
        await sleep(delaySec * 1000);
        attempt++;
      } else {
        throw lastError;
      }
    }
  }

  throw lastError;
}

/**
/**
 * 格式化结构清晰、直观易懂的签到状态汇报播报
 * 参考业界标准与 WorkBuddy 播报设计，同时深度契合 Trae 官方接口字段
 * 彻底分离「状态查询」与「签到执行」，杜绝误导用户
 *
 * @param {Object} options 播报参数对象
 * @param {Object} [options.statusData] 状态查询返回的数据对象
 * @param {string} options.queryStatus 状态查询结果说明
 * @param {string} options.claimStatus 今日签到执行结果说明
 * @param {string} [options.processFlow] 处理流程步骤可视化，如 "[Y] 查询状态 -> [X] 签到领取 -> [Y] 注册稍后重试"
 * @param {string} [options.userTip] 明确给用户的提示与建议
 * @param {number} [options.claimedCredits] 本次签到成功领取的积分数
 */
function formatSummary({
  statusData = null,
  queryStatus = '查询成功',
  claimStatus = '未知',
  processFlow = '',
  userTip = '',
  claimedCredits = null
} = {}) {
  const d = statusData || {};
  const baseCredits = d.credits !== undefined ? d.credits : 150;
  const extraCredits = d.extra_credits !== undefined ? d.extra_credits : 50;
  const dailyTotal = baseCredits + extraCredits;

  const lines = [];
  lines.push('===== TraeWork 每日签到播报 =====');
  lines.push(`状态查询：${queryStatus}`);
  lines.push(`今日签到：${claimStatus}`);

  // 自适应兼容：若官方未来在接口中扩充了连签与累计积分字段，优先展示
  if (d.streak_days !== undefined) {
    lines.push(`连续签到：${d.streak_days} 天`);
  }
  if (d.total_credits !== undefined) {
    lines.push(`累计积分：${d.total_credits}`);
  }

  lines.push(`每日奖励：${dailyTotal} 积分（基础 ${baseCredits} + 额外 ${extraCredits}）`);

  if (d.enable !== undefined) {
    lines.push(`活动状态：${d.enable ? '进行中' : '活动未开启或维护中'}`);
  }

  if (processFlow) {
    lines.push(`处理流程：${processFlow}`);
  }

  if (userTip) {
    lines.push(`温馨提示：${userTip}`);
  }

  lines.push('=================================');
  return lines.join('\n');
}

// ---- 主程序生命周期与业务决策 ---------------------------------------

async function main() {
  const silent = process.argv.includes('--silent') || process.argv.includes('-s');
  const dryRun = process.argv.includes('--dry-run');
  const force = process.argv.includes('--force');

  writeLog('=============================================');
  writeLog(`TraeWorkCheckin 自动签到程序启动 (PID: ${process.pid})`, 'START');

  // 1. 开机网络异步就绪与自愈探测
  const online = await waitForNetwork(300, 5);
  if (!online) {
    showNotification('TraeWork 签到提示', '网络长时间未连接，签到未执行。系统已安排稍后自动重试。');
    registerRetryTask();
    writeLog('本次任务因网络未就绪退出（退出码: 1）。已启动后台稍后自动重试机制。', 'FINISH');
    process.exit(1);
  }

  // 2. 防风控随机抖动延迟（仅在开机自启静默模式下打散固定时间指纹）
  if (silent && !dryRun && !force) {
    const jitterMs = Math.floor(Math.random() * 3000) + 2000; // 2~5 秒浮动延时
    await sleep(jitterMs);
  }

  // 3. 动态定位本地登录凭据
  let storageInfo;
  try {
    storageInfo = findStorageFile();
    writeLog(`已定位 Trae 客户端配置文件: ${storageInfo.path}`, 'AUTH');
  } catch (e) {
    writeLog(`未检测到登录态文件: ${e.message}`, 'ERROR');
    showNotification('TraeWork 异常提醒', '未检测到有效登录凭据，请先打开客户端登录。');
    process.exit(2);
  }

  const storage = storageInfo.data;

  // 4. 解密凭据并校验 Token
  let auth;
  try {
    const rawAuth = await decrypt(storage['iCubeAuthInfo://icube.cloudide']);
    auth = JSON.parse(rawAuth);
  } catch (err) {
    writeLog(`解密登录态失败: ${err.message}`, 'ERROR');
    showNotification('TraeWork 异常提醒', '解密登录凭据失败，请重新登录 Trae 客户端。');
    process.exit(2);
  }

  if (!auth.token) {
    writeLog('凭据中未找到有效 Token，请重新登录 Trae 客户端。', 'ERROR');
    showNotification('TraeWork 登录失效提醒', '凭据中未找到有效 Token，请重新登录 Trae 客户端。');
    process.exit(2);
  }

  if (auth.expiredAt && auth.expiredAt * 1000 < Date.now()) {
    writeLog('本地记录的 Token 已过有效期，尝试请求若报 401 请重新打开 Trae 客户端刷新登录。', 'WARN');
  }

  // 5. 提取真实字节跳动设备 ID（DID）与客户端版本识别
  let realDeviceId = '';
  for (const key of Object.keys(storage)) {
    const match = key.match(/iCubeAuthInfo:\/\/icube-dc:(\d+)/);
    if (match) {
      realDeviceId = match[1];
      break;
    }
  }
  if (!realDeviceId && storageInfo.path) {
    try {
      const localEnvPath = path.join(path.dirname(storageInfo.path), '..', '..', 'ModularData', 'ckg_server', 'local_env.json');
      if (fs.existsSync(localEnvPath)) {
        const envJson = JSON.parse(fs.readFileSync(localEnvPath, 'utf8'));
        if (envJson.device_id) realDeviceId = String(envJson.device_id);
      }
    } catch (e) {}
  }
  const deviceId = realDeviceId || storage['telemetry.devDeviceId'] || '';

  // 识别客户端来源类型 (TRAE SOLO CN 为 2，普通版 Trae CN 为 1)
  const isSolo = (storageInfo.dirName && storageInfo.dirName.toLowerCase().includes('solo')) ||
                 (storageInfo.path && storageInfo.path.toLowerCase().includes('solo'));
  const reqSource = isSolo ? 2 : 1;

  // 严格装配拟真官方完整设备请求头 (大小写与官方客户端 100% 保持一致)
  const headers = {
    'Authorization': `Cloud-IDE-JWT ${auth.token}`,
    'Content-Type': 'application/json',
    'x-device-id': deviceId,
    'x-device-type': process.platform === 'win32' ? 'Windows' : (process.platform === 'darwin' ? 'Darwin' : 'Linux'),
    'x-os-version': os.release ? os.release() : '',
    'X-Machine-Id': storage['telemetry.machineId'] || '',
    'X-Device-Id': deviceId,
    'X-User-Id': String(auth.userId || ''),
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Trae/1.0.0 Chrome/120.0.0.0 Electron/28.0.0 Safari/537.36'
  };
  if (auth.userRegion && auth.userRegion.region) {
    headers['X-User-Region'] = auth.userRegion.region;
  }

  writeLog(`登录凭据解析成功（用户: ${maskUserId(auth.userId)}，关联客户端: ${storageInfo.dirName}，DID: ${deviceId ? maskUserId(deviceId) : '自动生成'}，来源: ${isSolo ? 'SOLO (2)' : '标准版 (1)'}）`, 'AUTH');

  // 6. 前置查询今日签到状态（先查后签）
  let statusData = null;
  let todayCheckedIn = false;
  let queryStatusText = '查询成功';
  let queryFailed = false;

  try {
    statusData = await fetchWithRetry(STATUS_URL, {
      method: 'POST',
      headers,
      body: JSON.stringify({ req_source: reqSource })
    }, 5);

    if (statusData && (statusData.code === 0 || statusData.code === undefined)) {
      todayCheckedIn = Boolean(statusData.checked_in);
    }

    if (todayCheckedIn) {
      queryStatusText = '查询成功（检测到今日已完成签到）';
      writeLog('【阶段 1/2：状态查询】成功！检测到今日已签到，无需重复请求。', 'QUERY');
    } else {
      queryStatusText = '查询成功（检测到今日尚未签到）';
      writeLog('【阶段 1/2：状态查询】成功！检测到今日尚未签到，正在准备发起签到...', 'QUERY');
    }
  } catch (e) {
    queryFailed = true;
    queryStatusText = `查询失败（${e.message}）`;
    if (e.message && e.message.includes('401')) {
      writeLog(`登录凭据已失效: ${e.message}`, 'ERROR');
      showNotification('TraeWork 登录失效提醒', '登录凭证已失效，请打开 Trae 客户端重新登录。');
      const summaryText = formatSummary({
        statusData: null,
        queryStatus: '查询失败（登录凭据已失效）',
        claimStatus: '未执行（需重新登录客户端）',
        processFlow: '[X] 状态查询 -> [!] 凭据失效告警',
        userTip: '本地登录态 Token 已过期，请打开 Trae 客户端重新登录以刷新凭据。'
      });
      if (!silent) console.log('\n' + summaryText);
      writeLog('本次任务因凭据失效退出（退出码: 2）。请重新登录 Trae 客户端。', 'FINISH');
      process.exit(2);
    }
    writeLog(`状态查询暂未成功（不阻断后续兜底流程）: ${e.message}`, 'WARN');
  }

  // Dry-Run 试运行模式处理
  if (dryRun) {
    writeLog('DRY-RUN 试运行模式：仅查询状态，不向官方执行实际签到请求。', 'DRYRUN');
    const summaryText = formatSummary({
      statusData,
      queryStatus: queryStatusText,
      claimStatus: todayCheckedIn ? '今日已签（试运行查看）' : '今日尚未签到（试运行查看）',
      processFlow: '[Y] 查询状态 -> [i] 试运行模式查看',
      userTip: '当前处于 Dry-Run 试运行模式，仅展示账户当前状态，未发起签到请求。'
    });
    console.log('\n' + summaryText);
    process.exit(0);
  }

  // 7. 核心防风控拦截：若今日已签到，秒级跳过，坚决不向 /claim 接口发 POST
  if (todayCheckedIn && !force) {
    const baseCredits = statusData ? (statusData.credits || 150) : 150;
    const extraCredits = statusData ? (statusData.extra_credits || 50) : 50;
    const totalCredits = baseCredits + extraCredits;

    const skipMsg = `【防风控拦截】今日已完成签到，秒级跳过！每日奖励: ${totalCredits} 积分 (基础: ${baseCredits}, 额外: ${extraCredits})`;
    writeLog(skipMsg, 'SKIP');

    const summaryText = formatSummary({
      statusData,
      queryStatus: queryStatusText,
      claimStatus: '今日已签（自动跳过）',
      processFlow: '[Y] 查询状态 -> [Y] 防风控跳过 -> [Y] 流程完毕',
      userTip: '今日签到任务已达成，无需重复签到。'
    });

    if (!silent) {
      console.log('\n' + summaryText);
    }

    showNotification('TraeWork 签到提示', `今日已完成签到，无需重复操作。\n每日奖励: ${totalCredits} 积分 (基础: ${baseCredits}, 额外: ${extraCredits})`);
    cleanRetryTask();
    writeLog('本次任务圆满完成（退出码: 0）。今日已签到，进程立即释放内存安全退出。', 'FINISH');
    process.exit(0);
  }

  // 若官方活动未开启，友好跳过
  if (statusData && statusData.enable === false && !force) {
    writeLog('官方签到活动当前未开启或维护中 (enable: false)，安全跳过。', 'INFO');
    const summaryText = formatSummary({
      statusData,
      queryStatus: '查询成功（官方活动未开启）',
      claimStatus: '活动未开放（自动跳过）',
      processFlow: '[Y] 查询状态 -> [i] 友好跳过 -> [Y] 流程完毕',
      userTip: 'Trae 官方签到活动当前未开放或维护中，程序已安全跳过。'
    });

    if (!silent) {
      console.log('\n' + summaryText);
    }

    showNotification('TraeWork 签到提示', '官方签到活动当前未开启或维护中。');
    cleanRetryTask();
    writeLog('本次任务圆满完成（退出码: 0）。活动未开启，进程立即释放内存安全退出。', 'FINISH');
    process.exit(0);
  }

  // 8. 执行签到领取
  writeLog('【阶段 2/2：发起签到】正在向官方接口发起签到领取请求...', 'CLAIM');
  let claimStatusText = '未知';
  let userTipText = '';
  let processFlowText = '';
  let exitCode = 1;
  let claimedCredits = 200;

  try {
    const claim = await fetchWithRetry(CLAIM_URL, {
      method: 'POST',
      headers,
      body: JSON.stringify({ req_source: reqSource })
    }, 8);

    if (claim.code === 0) {
      claimedCredits = claim.data && claim.data.credits ? claim.data.credits : (statusData ? (statusData.credits || 150) + (statusData.extra_credits || 50) : 200);
      claimStatusText = `签到成功（+${claimedCredits} 积分已到账）`;
      userTipText = `恭喜！今日签到成功，已顺利领取 ${claimedCredits} 积分。`;
      processFlowText = '[Y] 查询状态 -> [Y] 签到领取 -> [Y] 流程完毕';
      writeLog(`【阶段 2/2：执行签到】恭喜！今日签到成功，已领取 ${claimedCredits} 积分！`, 'SUCCESS');
      exitCode = 0;
    } else if (claim.code === 9074) {
      claimStatusText = '签到暂未成功（服务器繁忙限流）';
      userTipText = '官方服务器早高峰并发限流，系统已自动安排 30 分钟后重试，无需人工干预。';
      processFlowText = '[Y] 查询状态 -> [X] 签到领取 -> [Y] 注册稍后自动重试';
      writeLog(`【阶段 2/2：执行签到】签到暂未完成：官方服务器繁忙限流 (Code 9074: ${claim.message || '当前参与用户太多，请稍后再试'})，已达本次最大重试次数。`, 'FAIL');
      exitCode = 1;
    } else {
      const failReason = claim.message || `错误码 ${claim.code}`;
      claimStatusText = `签到未成功（官方提示: ${failReason}）`;
      userTipText = `官方接口返回未成功 (${failReason})，系统已自动安排 30 分钟后重试。`;
      processFlowText = '[Y] 查询状态 -> [X] 签到领取 -> [Y] 注册稍后自动重试';
      writeLog(`【阶段 2/2：执行签到】接口未返回成功 (Code: ${claim.code}): ${failReason}`, 'FAIL');
      exitCode = 1;
    }
  } catch (err) {
    if (err.message && err.message.includes('401')) {
      writeLog(`签到时登录凭据已失效: ${err.message}`, 'ERROR');
      showNotification('TraeWork 登录失效提醒', '签到凭据已失效，请打开 Trae 客户端重新登录。');
      const summaryText = formatSummary({
        statusData,
        queryStatus: queryStatusText,
        claimStatus: '签到失败（凭证过期）',
        processFlow: '[Y] 查询状态 -> [X] 签到领取 -> [!] 提醒重新登录',
        userTip: '签到凭据在请求中已失效，请打开 Trae 客户端重新登录。'
      });
      if (!silent) console.log('\n' + summaryText);
      writeLog('本次任务因凭据失效退出（退出码: 2）。请重新登录 Trae 客户端。', 'FINISH');
      process.exit(2);
    }
    claimStatusText = `请求失败（${err.message}）`;
    userTipText = `网络或请求异常（${err.message}），系统已自动安排 30 分钟后重试。`;
    processFlowText = (queryFailed ? '[X] 状态查询' : '[Y] 查询状态') + ' -> [X] 签到领取 -> [Y] 注册稍后自动重试';
    writeLog(`【阶段 2/2：执行签到】请求发生异常: ${err.message}`, 'ERROR');
    exitCode = 1;
  }

  // 9. 状态刷新、自愈清理与用户反馈
  if (exitCode === 0) {
    // 再次静默获取最新积分状态
    try {
      const updatedStatus = await fetchWithRetry(STATUS_URL, {
        method: 'POST',
        headers,
        body: JSON.stringify({ req_source: reqSource })
      }, 2);
      if (updatedStatus && updatedStatus.code === 0) {
        statusData = updatedStatus;
      }
    } catch (e) {
      // 忽略二次刷新状态异常
    }

    cleanRetryTask(); // 自愈注销临时重试任务
    showNotification('TraeWork 签到成功', `恭喜！今日签到成功！\n已领取: ${claimedCredits} 积分到账`);
  } else {
    // 签到失败，激活第二道防线：注册稍后自动重试计划
    registerRetryTask();
    showNotification('TraeWork 签到提示', '今日签到暂未成功（服务器繁忙限流），系统已安排稍后自动重试。');
  }

  // 10. 极速资源回收与零内存常驻退出
  const summaryText = formatSummary({
    statusData,
    queryStatus: queryStatusText,
    claimStatus: claimStatusText,
    processFlow: processFlowText,
    userTip: userTipText,
    claimedCredits
  });

  if (!silent) {
    console.log('\n' + summaryText);
  }

  if (exitCode === 0) {
    writeLog('本次任务圆满完成（退出码: 0）。今日签到流程闭环，进程立即释放内存安全退出。', 'FINISH');
  } else {
    writeLog(`本次任务签到暂未完成（退出码: ${exitCode}）。已激活后台稍后自动重试兜底，进程立即释放内存安全退出。`, 'FINISH');
  }
  process.exit(exitCode);
}

// 统一顶级异常捕获，确保不静默丢失错误上下文
main().catch(err => {
  const errMsg = `程序顶层执行异常: ${err.message}`;
  writeLog(errMsg, 'ERROR');
  showNotification('TraeWork 异常提醒', errMsg);
  process.exit(1);
});
