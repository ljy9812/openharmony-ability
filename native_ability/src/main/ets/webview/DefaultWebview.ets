import { UIContext } from "@ohos.arkui.UIContext";
import web_webview from "@ohos.web.webview";
import { ComponentContent, NodeController, BuilderNode, FrameNode } from "@ohos.arkui.node";
import { hilog } from '@kit.PerformanceAnalysisKit';
import { buffer } from '@kit.ArkTS';
import { randomString } from "../helper";
import { OnDownloadStartResult, OnWindowNewResult } from "../ability/type";
import { getCookies, setCookie, setWebDebuggingAccess, isWebDebuggingAccess, JsHelper, convertRRGGBBAAtoAARRGGBB, SnapshotData } from "./Utils";
import { WebHeader, AttributeUpdater } from "@kit.ArkUI";
import { router } from '@kit.ArkUI';
import { fileUri } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { WindowManager } from '../window/WindowManager';
import { DOMAIN } from '../helper/constants';
import { openNewWindowDialog } from "./NewWindowDialog";
import { notifyPrimaryWebviewController } from "../components/DefaultXComponent";
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import printKit from '@ohos.print';
import { unifiedDataChannel, uniformTypeDescriptor, uniformDataStruct } from '@kit.ArkData';

const DEFAULT_PDF_CONFIG: web_webview.PdfConfiguration = {
  width: 8.27,              // A4 width in inches (210mm / 25.4)
  height: 11.69,            // A4 height in inches (297mm / 25.4)
  marginTop: 0,
  marginBottom: 0,
  marginRight: 0,
  marginLeft: 0,
  shouldPrintBackground: true
};

/**
 * Shared onWindowNew handler for both WebBuilder and EmbeddedWebBuilder.
 * Parses event params, calls the NAPI callback, and either opens a dialog,
 * creates a real OS sub-window, or denies.
 */
function handleWindowNew(
  event: { targetUrl?: string; isAlert?: boolean; isUserTrigger?: boolean; handler: { setWebController: (ctrl: web_webview.WebviewController | null) => void } },
  data: WebviewNodeData,
  tag: string,
): void {
  const targetUrl: string = event.targetUrl ?? '';
  const isAlert: boolean = event.isAlert ?? false;
  const isUserTrigger: boolean = event.isUserTrigger ?? false;
  hilog.info(DOMAIN, 'DefaultWebview', '%{public}s onWindowNew: targetUrl=%{public}s, isAlert=%{public}s, isUserTrigger=%{public}s',
    tag, targetUrl, String(isAlert), String(isUserTrigger));
  try {
    if (typeof data?.onWindowNew === 'function') {
      const result: OnWindowNewResult = data.onWindowNew(targetUrl, isAlert, isUserTrigger);
      hilog.info(DOMAIN, 'DefaultWebview', '%{public}s onWindowNew: result={allow:%{public}s, isCreate:%{public}s}', tag, String(result.allow), String(result.isCreate));
      if (result.isCreate) {
        // Create mode: the embedding runtime's handler already created a real OS window
        // via WebviewWindowBuilder::build() → createOSWindow.
        // Call setWebController(null) to tell ArkWeb NOT to create its own window,
        // preventing double windows.
        // Note: if the handler failed to create a window, this results in a silent no-op
        // (no dialog, no window). The handler should log errors on its side.
        hilog.info(DOMAIN, 'DefaultWebview', '%{public}s onWindowNew: CREATE — OS window already created by handler', tag);
        event.handler.setWebController(null);
      } else if (result.allow) {
        // Allow mode: open in-page dialog
        hilog.info(DOMAIN, 'DefaultWebview', '%{public}s onWindowNew: ALLOW — opening dialog', tag);
        const newCtrl = new web_webview.WebviewController();
        event.handler.setWebController(newCtrl);
        if (data?.uiContext) {
          const uiCtx = data.uiContext;
          hilog.info(DOMAIN, 'DefaultWebview', '%{public}s onWindowNew: scheduling openNewWindowDialog', tag);
          setTimeout(() => {
            openNewWindowDialog(uiCtx, newCtrl, targetUrl);
          }, 0);
        } else {
          hilog.warn(DOMAIN, 'DefaultWebview', '%{public}s onWindowNew: no uiContext, cannot open dialog', tag);
        }
      } else {
        hilog.info(DOMAIN, 'DefaultWebview', '%{public}s onWindowNew: DENY', tag);
        event.handler.setWebController(null);
      }
    } else {
      hilog.warn(DOMAIN, 'DefaultWebview', '%{public}s onWindowNew: no handler (data.onWindowNew not a function), default DENY', tag);
      event.handler.setWebController(null);
    }
  } catch (e) {
    hilog.error(DOMAIN, 'DefaultWebview', '%{public}s onWindowNew exception, calling setWebController(null): %{public}s',
      tag, JSON.stringify(e));
    event.handler.setWebController(null);
  }
}

/**
 * Build a WebResourceResponse from a JSON string returned by Rust
 * `dispatchHttpsIntercept`. JSON shape:
 *   { "status": number, "mimeType": string, "body": "<base64>" }
 * Returns null on parse/decode failure so ArkWeb falls back to default loading.
 */
function buildInterceptResponse(json: string): WebResourceResponse | null {
  try {
    const parsed = JSON.parse(json) as { status: number; mimeType: string; body: string };
    const response = new WebResourceResponse();
    const buf = buffer.from(parsed.body || '', 'base64');
    // buf.buffer may be larger than the actual decoded data (internal pooling/
    // alignment). Slice the exact region to avoid garbage bytes in the response.
    // Note: ArkTS Buffer uses .length (not .byteLength) for decoded data length.
    response.setResponseData(buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.length));
    response.setResponseMimeType(parsed.mimeType || 'application/octet-stream');
    response.setResponseCode(parsed.status || 200);
    response.setResponseIsReady(true);
    return response;
  } catch (e) {
    hilog.error(DOMAIN, 'DefaultWebview', 'buildInterceptResponse failed: %{public}s', JSON.stringify(e));
    return null;
  }
}

/**
 * Shared onInterceptRequest handler for WebBuilder and EmbeddedWebBuilder.
 *
 * Matches `https://<protocol>.<host>/<path>` against `data.httpsInterceptProtocolsSet`.
 * On match: synchronously calls `data.dispatchHttpsIntercept(url)` (NAPI into
 * Rust), builds a WebResourceResponse from the returned JSON, and returns it.
 * On no match or when https intercept is disabled: returns null so ArkWeb
 * continues with the default network stack.
 *
 * The callback is always attached when `data.useHttpsIntercept === true`; when
 * the flag is false/undefined the Web component is built without this attribute
 * (guarded by the caller).
 */
function handleInterceptRequest(
  data: WebviewNodeData,
  event: { request: WebResourceRequest },
): WebResourceResponse | null {
  if (!event || !event.request) return null;
  if (data?.useHttpsIntercept !== true) return null;
  const protocolsSet = data?.httpsInterceptProtocolsSet;
  if (!protocolsSet || protocolsSet.size === 0) return null;
  const url = event.request.getRequestUrl();
  if (!url) return null;
  const prefix = 'https://';
  if (!url.startsWith(prefix)) return null;
  const rest = url.substring(prefix.length);
  const dotIdx = rest.indexOf('.');
  if (dotIdx <= 0) return null;
  const protocol = rest.substring(0, dotIdx);
  if (!protocolsSet.has(protocol)) return null;
  if (typeof data?.dispatchHttpsIntercept !== 'function') {
    hilog.warn(DOMAIN, 'DefaultWebview', 'onInterceptRequest: dispatchHttpsIntercept not installed for %{public}s', protocol);
    return null;
  }
  let json: string | null = null;
  try {
    json = data.dispatchHttpsIntercept(url);
  } catch (e) {
    hilog.error(DOMAIN, 'DefaultWebview', 'onInterceptRequest dispatch failed: %{public}s', JSON.stringify(e));
    return null;
  }
  if (!json) return null;
  return buildInterceptResponse(json);
}

/**
 * Map a numeric blur radius to a HarmonyOS BlurStyle enum value.
 * Used for `backgroundBlurStyle` (transparent main windows only).
 * For opaque windows (Float sub-windows), `backdropBlur(radius)` is used directly
 * since it blurs in-surface pixels and works on opaque containers.
 * Available since API 9.
 *
 * When radius=0 (effects cleared), BACKGROUND_THIN is used as minimal fallback —
 * the visual clearing is done by backgroundColor reset in clear_ohos_blur.
 */
function radiusToBlurStyle(radius: number): BlurStyle {
  if (radius <= 20) return BlurStyle.BACKGROUND_THIN;
  if (radius <= 40) return BlurStyle.BACKGROUND_REGULAR;
  if (radius <= 60) return BlurStyle.BACKGROUND_THICK;
  return BlurStyle.BACKGROUND_ULTRA_THICK;
}

/**
 * AttributeUpdater for runtime blur refresh.
 * BuilderNode.update does not refresh blur attributes, so we use AttributeUpdater to
 * directly modify the Stack's blur attribute at runtime (setWindowBlur path).
 * attribute?.X(style) triggers an immediate component update without @State.
 *
 * API selection based on `transparent` flag:
 * - transparent=true: `backgroundBlurStyle` — system material blur sampling content
 *   behind the window. Requires transparent container (main window only).
 * - transparent=false: `backdropBlur` — blurs in-surface pixels. Works on opaque
 *   containers (Float sub-windows where setWindowContainerColor returns 1300004).
 */
export class BlurModifier extends AttributeUpdater<CommonAttribute> {
  /** Whether the window uses transparent container (determines blur API selection). */
  transparent?: boolean;
  initializeModifier(_instance: CommonAttribute): void {
    // Intentionally empty: let the build-time Stack blur attribute take effect.
    // Runtime setWindowBlur refreshes via applyBlur(radius).
  }
  /** Apply blur using the correct API for this window's transparency mode. */
  applyBlur(radius: number): void {
    if (!this.attribute) {
      hilog.warn(DOMAIN, 'DefaultWebview', '[DBG] BlurModifier.applyBlur: attribute is null, radius=%{public}d', radius);
      return;
    }
    const style = radiusToBlurStyle(radius);
    if (this.transparent === true) {
      hilog.info(DOMAIN, 'DefaultWebview', '[DBG] BlurModifier.applyBlur: backgroundBlurStyle radius=%{public}d style=%{public}d transparent=%{public}s', radius, style, String(this.transparent));
      this.attribute.backgroundBlurStyle(style);
    } else {
      hilog.info(DOMAIN, 'DefaultWebview', '[DBG] BlurModifier.applyBlur: backdropBlur radius=%{public}d transparent=%{public}s', radius, String(this.transparent));
      this.attribute.backdropBlur(radius);
    }
  }
}

export interface WebviewStyle {
  x?: number | string;
  y?: number | string;
  width?: number | string;
  height?: number | string;
  backgroundColor?: string | Color | number;
  visible?: boolean;
  blurRadius?: number;
}

export interface WebviewInitData {
  webTag?: string;
  url: string;
  windowId?: number;
  style?: WebviewStyle;
  controller?: WebviewController;
  uiContext?: UIContext;
  javascriptEnable?: boolean;
  devtools?: boolean;
  autoplay?: boolean;
  userAgent?: string;
  initializationScripts?: ScriptItem[];
  headers?: Record<string, string>;
  html?: string;
  transparent?: boolean;
  clipboard?: boolean;
  zoomHotkeysEnabled?: boolean;
  dragDropOverlay?: boolean;
  useHttpsIntercept?: boolean;
  httpsInterceptProtocols?: string[];
  // Live per-webview protocol set. `registerHttpsIntercept` adds to this set;
  // `onInterceptRequest` reads it to decide whether to intercept.
  httpsInterceptProtocolsSet?: Set<string>;
  // Synchronous bridge into Rust (nativeModule.dispatchHttpsIntercept). Returns
  // a JSON string `{"status":u16,"mimeType":String,"body":"base64..."}` or null.
  dispatchHttpsIntercept?: (url: string) => string | null;
  onDragAndDrop?: (event: string) => void;
  onDownloadStart?: (url: string, tempPath: string | undefined) => OnDownloadStartResult;
  onDownloadEnd?: (url: string, tempPath: string | undefined, success: boolean) => void;
  onNavigationRequest?: (url: string) => boolean;
  onTitleChange?: (title: string) => void;
  onPageBegin?: (url: string) => void;
  onPageEnd?: (url: string) => void;
  onCloseWindow?: () => void;
  onWindowNew?: (targetUrl: string, isAlert: boolean, isUserTrigger: boolean) => OnWindowNewResult;
}

interface WebviewNodeData extends WebviewInitData {
  controller: WebviewController;
  didInitialLoad?: boolean;
  blurModifier?: BlurModifier;
  // True when the webview was created WITHOUT explicit style.width — it fills
  // its parent container ("100%") and runtime set_bounds width/height is
  // stripped for it in updateWebviewStyle (upstream d530828 port).
  naturalLayout?: boolean;
  // Trailing-debounce timer for the onAreaChange → runJavaScript(resize) dispatch.
  // ArkWeb in ASYNC_RENDER mode does not reliably reflow its viewport when the
  // Web component's ArkUI layout box changes; see WebBuilder.onAreaChange.
  resizeRafTimer?: number;
}

/**
 * Drag-drop pipe-string helpers. Wire format: "<type>|<paths_nul>|<x>,<y>".
 * Paths are \0-separated (null byte) to tolerate paths containing commas, matching
 * the webview backend's drag.rs `from_arkts_pipe` (\0-split). See ohos-webview-drag-drop spec.
 *
 * ArkUI DragEvent: getData() returns a UDMF UnifiedData (NOT a string) and is only valid in
 * onDrop (per the DragEvent get-method table); enter/move/leave pass withPaths=false. getX()/getY()
 * are valid in all four drag callbacks; (0,0) on any error.
 *
 * Record URI extraction: each UnifiedRecord is dispatched via getTypes()/getEntry() (confirmed in
 * unified-data-channels.md) to its UDMF concrete struct. File-manager file drags arrive as
 * UniformDataType.FILE_URI → uniformDataStruct.FileUri.oriUri (confirmed via arkts-helper; follows
 * the PLAIN_TEXT→PlainText / HTML→HTML convention). Image drags (e.g. from Photos) fall back to
 * the unifiedDataChannel.Image.imageUri narrowing (ArkUI drag guide). Unknown types are
 * hilog-logged for device-side discovery. file:// / datashare:// schemes are stripped so the Rust
 * side receives an absolute filesystem path.
 */
function buildDragPipe(type: string, dragEvent: DragEvent, withPaths: boolean): string {
  const pathsNul: string = withPaths ? extractDragPaths(dragEvent) : '';
  // On drop, call setResult(DRAG_SUCCESSFUL) — per the ArkUI drag guide this tells the system
  // "data handled by the app, skip default drop handling". NOTE: correct for generic ArkUI
  // components but PROVEN INEFFECTIVE on the Web component (verified on device: ArkWeb consumes
  // the drop and navigates to file://<dragged file> before ArkUI dispatches onDrop, so setResult
  // never runs / has no effect; .txt and .html both trigger the navigation, httpStatus:0). The
  // reliable fix for the Web component is the file:// branch in onLoadIntercept (blocks the
  // navigation + forwards the path). The setResult call is retained here as a harmless no-op
  // that stays correct if this helper is reused on a generic (non-Web) component.
  if (type === 'drop') {
    try { dragEvent.setResult(DragResult.DRAG_SUCCESSFUL); } catch (e) { /* setResult not available */ }
  }
  return type + '|' + pathsNul + '|' + readDragPos(dragEvent);
}

function extractDragPaths(dragEvent: DragEvent): string {
  // getData() is only valid in onDrop; callers pass withPaths=false for enter/move/leave.
  try {
    const ud: unifiedDataChannel.UnifiedData = dragEvent.getData();
    if (!ud) { return ''; }
    const records: Array<unifiedDataChannel.UnifiedRecord> = ud.getRecords();
    if (!records || records.length === 0) { return ''; }
    hilog.info(DOMAIN, 'DefaultWebview', 'drag drop: %{public}d record(s) received', records.length);
    const uris: Array<string> = [];
    for (let i = 0; i < records.length; i++) {
      const uri = extractRecordUri(records[i]);
      if (uri.length > 0) { uris.push(uri); }
    }
    return uris.join('\0');
  } catch (e) { return ''; }
}

function extractRecordUri(record: unifiedDataChannel.UnifiedRecord): string {
  // Dispatch via getTypes()/getEntry() — confirmed UDMF pattern (unified-data-channels.md:150-158).
  try {
    const types = record.getTypes();
    // Primary: file-manager file drags → FILE_URI (confirmed via arkts-helper; follows the
    // PLAIN_TEXT→PlainText convention). Covers all file-manager drags, including image files.
    if (types.includes(uniformTypeDescriptor.UniformDataType.FILE_URI)) {
      const fileUriUds = record.getEntry(uniformTypeDescriptor.UniformDataType.FILE_URI) as uniformDataStruct.FileUri;
      if (fileUriUds && fileUriUds.oriUri) { return stripDragScheme(fileUriUds.oriUri); }
    }
    // Fallback: image drags from Photos/gallery → Image record (ArkUI drag guide).
    const img = record as unifiedDataChannel.Image;
    if (img && img.imageUri) { return stripDragScheme(img.imageUri); }
    // Unknown record type — log for device-side type discovery (Phase 5).
    hilog.info(DOMAIN, 'DefaultWebview', 'drag record types: %{public}s', types.join(','));
  } catch (e) { /* record type not extractable */ }
  return '';
}

function readDragPos(dragEvent: DragEvent): string {
  try {
    const x = dragEvent.getX();
    const y = dragEvent.getY();
    return x + ',' + y;
  } catch (e) { return '0,0'; }
}

// Strip file:// / datashare:// so Rust receives an absolute filesystem path.
// Defensive no-op if the URI has no known scheme.
function stripDragScheme(raw: string): string {
  if (raw.startsWith('file://')) { return raw.substring('file://'.length); }
  if (raw.startsWith('datashare://')) { return raw.substring('datashare://'.length); }
  return raw;
}

@Builder
function WebBuilder(data: WebviewNodeData) {
  // init with empty url and reload with loadUrl or loadData with onControllerAttach
  // NOTE: data.blurModifier is initialized in addWebview (cannot assign inside @Builder).
  // Runtime setWindowBlur refreshes blur via BlurModifier.applyBlur(radius) which
  // selects backgroundBlurStyle (transparent=true) or backdropBlur (transparent=false).
  Stack() {
    Web({
      src: "",
      controller: data.controller as web_webview.WebviewController,
      renderMode: data?.transparent ? RenderMode.SYNC_RENDER : RenderMode.ASYNC_RENDER
    })
      // Natural-layout webviews (no explicit style.width — the main webview of
      // each window) use "100%" so the Web follows the Stack/window layout on
      // resize; the .onAreaChange handler below dispatches a resize event to the
      // page so ArkWeb (ASYNC_RENDER) re-evaluates its viewport against the new
      // size. Child webviews created with explicit bounds (wry is_child →
      // WebViewStyle width/height) keep their explicit px sizing — sizing a
      // natural webview explicitly would desync from the window
      // (BuilderNode.update does not notify ArkWeb to relayout → after window
      // resize the page keeps the old layout and the bottom is cut off; that
      // regression is guarded by naturalLayout in updateWebviewStyle).
      // (set_bounds still sets data.style.x/y for .position below.)
      .width(data.style?.width ?? "100%")
      .height(data.style?.height ?? "100%")
      .position({
        x: data.style?.x ?? 0,
        y: data.style?.y ?? 0,
      })
      // When transparent=true, force Web background to Color.Transparent so the
      // parent Stack's backgroundBlurStyle (vibrancy effect) is visible through the Web
      // component. Without this, the Web component renders with its default opaque
      // background, completely hiding the backgroundBlurStyle effect.
      .backgroundColor(data?.transparent ? Color.Transparent : convertRRGGBBAAtoAARRGGBB(data?.style?.backgroundColor))
      .visibility(data?.style?.visible === false ? Visibility.Hidden : Visibility.Visible)
      // ArkWeb in ASYNC_RENDER mode (default; non-transparent windows) does NOT
      // reliably sync its render surface / viewport when the Web component's ArkUI
      // layout box changes — after a manual window resize the page keeps the old
      // layout and the bottom is cut off. SYNC_RENDER (transparent windows) syncs
      // automatically, so the dispatch is a harmless no-op there.
      //
      // The Web component's "100%" layout box DOES update on resize for BOTH the
      // main window (win.on("windowSizeChange") → ArkUI relayout) and Float
      // sub-windows (win.resize() in FloatPage gesture handlers → ArkUI relayout).
      // onAreaChange fires in both cases → dispatch a resize event to the page so
      // responsive layouts re-evaluate against the new viewport.
      //
      // Fire-and-forget (runJavaScript returns a Promise we don't await) — matches
      // the bridge plugin pattern and avoids main-thread blocking. A trailing
      // 50ms debounce collapses the rapid onAreaChange burst during drag-resize.
      .onAreaChange((_oldArea: Area, newArea: Area) => {
        hilog.info(DOMAIN, 'DefaultWebview', '[DBG] onAreaChange: w=%{public}s h=%{public}s',
          String(newArea?.width), String(newArea?.height));
        if (data.resizeRafTimer !== undefined) {
          clearTimeout(data.resizeRafTimer);
        }
        data.resizeRafTimer = setTimeout(() => {
          data.resizeRafTimer = undefined;
          try {
            data.controller.runJavaScript('window.dispatchEvent(new Event("resize"));')
              .catch((err) => {
                hilog.warn(DOMAIN, 'DefaultWebview', 'onAreaChange resize dispatch failed: %{public}s', String(err?.message || err));
              });
          } catch (err) {
            hilog.warn(DOMAIN, 'DefaultWebview', 'onAreaChange runJavaScript threw: %{public}s', String(err?.message || err));
          }
        }, 50);
      })
    .javaScriptAccess(data?.javascriptEnable)
    .domStorageAccess(true)
    .mediaPlayGestureAccess(
      typeof data?.autoplay === "boolean" && data.autoplay === true ? false : true,
    )
    .javaScriptOnDocumentStart(data?.initializationScripts)
    .onControllerAttached(() => {
      hilog.info(DOMAIN, 'DefaultWebview', 'onControllerAttached fired');
      // Guard against repeated onControllerAttached calls (re-render or system events)
      if (data.didInitialLoad === true) {
        return;
      }
      data.didInitialLoad = true;
      const ctrl = data.controller;
      // Set up download delegate after controller is attached
      setupDownloadDelegate(data);
      // Inject controller into PredefinedActionExecutor so copy/cut/paste/selectAll/
      // undo/redo (edit-menu commands) operate on this webview. Mirrors
      // WebviewPlugin.ets onControllerAttached — injection must happen after
      // setupDownloadDelegate (audit-corrected ordering).
      notifyPrimaryWebviewController(ctrl as ESObject);
      // Set custom User-Agent if provided
      if (data.userAgent) {
        try {
          ctrl.setCustomUserAgent(data.userAgent);
        } catch (error) {
          hilog.error(DOMAIN, 'DefaultWebview', 'setCustomUserAgent failed: %{public}s', JSON.stringify(error));
        }
      }
      // load url or html string
      if (data?.url) {
        const header: WebHeader[] = Object.keys(
          (data?.headers || {}) as Record<string, string>,
        ).reduce((t: WebHeader[], i) => {
          t.push({ headerKey: i, headerValue: data.headers![i] } as WebHeader);
          return t;
        }, []);
        ctrl.loadUrl(data.url, header);
      } else {
        ctrl.loadData(data!.html, "text/html", "UTF-8", " ", " ");
      }
    })
    .onErrorReceive((event) => {
      hilog.error(DOMAIN, 'DefaultWebview', 'Web onErrorReceive: %{public}s', JSON.stringify(event));
      if (event.error) {
        // Only replace page content for main frame errors; ignore sub-resource errors
        if (!event.request.isMainFrame()) {
          hilog.warn(DOMAIN, 'DefaultWebview', 'Sub-resource error ignored, code: %{public}d', event.error.getErrorCode());
          return;
        }
        const ctrl = data.controller;
        const errorCode = event.error.getErrorCode();
        const errorInfo = event.error.getErrorInfo();
        hilog.error(DOMAIN, 'DefaultWebview', 'Main frame load failed: %{public}d - %{public}s', errorCode, errorInfo);

        const errorHtml = `
          <html>
            <body style="display:flex;justify-content:center;align-items:center;height:100vh;margin:0;background:#f5f5f5;font-family:sans-serif;">
              <div style="text-align:center;padding:20px;">
                <h2>Network Error</h2>
                <p>Failed to load the page. Please check your connection.</p>
                <p style="color:#666;font-size:12px;">Error: ${errorCode} - ${errorInfo}</p>
              </div>
            </body>
          </html>
        `;
        ctrl.loadData(errorHtml, 'text/html', 'UTF-8', ' ', ' ');
      }
    })
    .onLoadIntercept((event) => {
      const url = event.data.getRequestUrl();
      // ArkWeb consumes OS file drops by navigating to file://<dropped file>, which then
      // fails (ERR_ACCESS_DENIED) and replaces the page (white screen). The Web-level
      // .onDrop is unreliable here: ArkWeb preempts it part of the time, and even when
      // .onDrop fires ArkWeb still navigates (setResult(DRAG_SUCCESSFUL) is ineffective on
      // the Web component — verified on device). Intercept the file:// navigation instead:
      // block it (return true) and forward the path through the drag-drop pipe so the app
      // receives a Drop event and the webview is preserved. Safe because the embedding runtime loads
      // via the consumer-registered custom protocol (custom scheme / https://<proto>.localhost) or inline html, never
      // file://, so legitimate loads are unaffected. See openspec ohos-webview-drag-drop.
      if (url && url.startsWith('file://')) {
        hilog.info(DOMAIN, 'DefaultWebview', 'onLoadIntercept file:// drop-consumption blocked: %{public}s', url);
        if (typeof data?.onDragAndDrop === 'function') {
          let path = '';
          try { path = stripDragScheme(decodeURIComponent(url)); } catch (e) { path = stripDragScheme(url); }
          data.onDragAndDrop('drop|' + path + '|0,0');
        }
        return true; // block navigation → no white screen
      }
      // OHOS: intercept close-window URL to destroy the parent window.
      // This is used by test windows that cannot attach JS event listeners
      // due to OHOS Web component initialization_script limitations.
      if (url && event.data.isMainFrame() && url.startsWith('http://close-window.invalid')) {
        hilog.info(DOMAIN, 'DefaultWebview', 'Intercepted close-window URL, destroying window %{public}d', data?.windowId ?? -1);
        if (typeof data?.onCloseWindow === 'function') {
          data.onCloseWindow();
        }
        return true; // block navigation
      }
      if (typeof data?.onNavigationRequest === "function") {
        hilog.info(DOMAIN, 'DefaultWebview', 'onLoadIntercept → onNavigationRequest called: %{public}s', url);
        // onLoadIntercept: true = block, false = allow
        // onNavigationRequest: true = allow, false = block
        // So we negate the return value
        const ret = data.onNavigationRequest(url);
        hilog.info(DOMAIN, 'DefaultWebview', 'onNavigationRequest result: %{public}s, onLoadIntercept returns: %{public}s', ret ? 'allow' : 'block', ret ? 'false(allow)' : 'true(block)');
        return !ret;
      }
      return false;
    })
    .onInterceptRequest((event) => {
      return handleInterceptRequest(data, event as { request: WebResourceRequest });
    })
    .onTitleReceive((e) => {
      if (typeof data?.onTitleChange === "function") {
        hilog.info(DOMAIN, 'DefaultWebview', 'onTitleReceive → onTitleChange called: %{public}s', e.title);
        data.onTitleChange(e.title);
      }
    })
    .onPageBegin((e) => {
      if (typeof data?.onPageBegin === "function") {
        data.onPageBegin(e.url);
      }
    })
    .onPageEnd((e) => {
      if (typeof data?.onPageEnd === "function") {
        data.onPageEnd(e.url);
      }
    })
    .multiWindowAccess(true)
    .allowWindowOpenMethod(true)
    .onWindowNew((event) => {
      handleWindowNew(event, data, 'WebBuilder');
    })
    // Drag-and-drop: forward to Rust via onDragAndDrop pipe string.
    // "<type>|<paths_csv>|<x>,<y>". See ohos-webview-drag-drop spec.
    // NOTE: whether ArkWeb bubbles OS file drops to these handlers is unverified
    // (device probe needed); overlay fallback is the contingency.
    .onDragEnter((dragEvent: DragEvent) => {
      if (data?.dragDropOverlay === true) return;
      if (typeof data?.onDragAndDrop === 'function') { data.onDragAndDrop(buildDragPipe('enter', dragEvent, false)); }
    })
    .onDragMove((dragEvent: DragEvent) => {
      if (data?.dragDropOverlay === true) return;
      if (typeof data?.onDragAndDrop === 'function') { data.onDragAndDrop(buildDragPipe('over', dragEvent, false)); }
    })
    .onDrop((dragEvent: DragEvent) => {
      if (data?.dragDropOverlay === true) return;
      if (typeof data?.onDragAndDrop === 'function') { data.onDragAndDrop(buildDragPipe('drop', dragEvent, true)); }
    })
    .onDragLeave((dragEvent: DragEvent) => {
      if (data?.dragDropOverlay === true) return;
      if (typeof data?.onDragAndDrop === 'function') { data.onDragAndDrop(buildDragPipe('leave', dragEvent, false)); }
    });
    if (data?.dragDropOverlay === true && typeof data?.onDragAndDrop === 'function') {
      Stack()
        .width("100%")
        .height("100%")
        .backgroundColor(Color.Transparent)
        .hitTestBehavior(HitTestMode.Transparent)
        .onDragEnter((dragEvent: DragEvent) => { data.onDragAndDrop(buildDragPipe('enter', dragEvent, false)); })
        .onDragMove((dragEvent: DragEvent) => { data.onDragAndDrop(buildDragPipe('over', dragEvent, false)); })
        .onDrop((dragEvent: DragEvent) => { data.onDragAndDrop(buildDragPipe('drop', dragEvent, true)); })
        .onDragLeave((dragEvent: DragEvent) => { data.onDragAndDrop(buildDragPipe('leave', dragEvent, false)); })
    }
  }
  .width("100%")
  .height("100%")
  .backgroundColor(Color.Transparent)
  // Blur API selection by window transparency:
  // - transparent=true (main window): `backgroundBlurStyle` samples content behind the
  //   transparent window (macOS vibrancy-like). Requires applyTransparentBackground.
  // - transparent=false (opaque, e.g. Float sub-windows): `backdropBlur` blurs in-surface
  //   pixels of the opaque Web background → visible frosted glass. backgroundBlurStyle
  //   would sample through to the opaque container → no visible effect.
  // backdropBlur was the API used before the aca6b53 refactor; it produced visible frosted
  // glass on sub-windows. The switch to backgroundBlurStyle caused the vibrancy regression.
  .backgroundBlurStyle(data?.transparent === true ? radiusToBlurStyle(data?.style?.blurRadius ?? 0) : BlurStyle.BACKGROUND_THIN)
  .backdropBlur(data?.transparent === true ? 0 : (data?.style?.blurRadius ?? 0))
  .attributeModifier(data.blurModifier)
}

@Builder
function EmbeddedWebBuilder(data: WebviewNodeData) {
  // The embedded path needs a bounded ArkTS root so hit testing stays clipped
  // to the host slot owned by native. A bare `Web` component can render in the
  // right place while still participating in input as an unbounded layer.
  Stack() {
    Web({
      src: "",
      controller: data.controller as web_webview.WebviewController,
      renderMode: data?.transparent ? RenderMode.SYNC_RENDER : RenderMode.ASYNC_RENDER
    })
      // Explicit bounds when provided (child webviews); "100%" natural layout
      // otherwise (see WebBuilder).
      .width(data.style?.width ?? "100%")
      .height(data.style?.height ?? "100%")
      .backgroundColor(convertRRGGBBAAtoAARRGGBB(data?.style?.backgroundColor))
      // Same ArkWeb ASYNC_RENDER viewport reflow nudge as WebBuilder — see the
      // onAreaChange comment there. Embedded webviews in resizable hosts hit
      // the same bottom-cutoff, so the dispatch is mirrored here.
      .onAreaChange((_oldArea: Area, _newArea: Area) => {
        if (data.resizeRafTimer !== undefined) {
          clearTimeout(data.resizeRafTimer);
        }
        data.resizeRafTimer = setTimeout(() => {
          data.resizeRafTimer = undefined;
          try {
            data.controller.runJavaScript('window.dispatchEvent(new Event("resize"));')
              .catch((err) => {
                hilog.warn(DOMAIN, 'DefaultWebview', 'onAreaChange(embedded) resize dispatch failed: %{public}s', String(err?.message || err));
              });
          } catch (err) {
            hilog.warn(DOMAIN, 'DefaultWebview', 'onAreaChange(embedded) runJavaScript threw: %{public}s', String(err?.message || err));
          }
        }, 50);
      })
      .javaScriptAccess(data?.javascriptEnable)
      .domStorageAccess(true)
      .mediaPlayGestureAccess(
        typeof data?.autoplay === "boolean" && data.autoplay === true ? false : true,
      )
      .javaScriptOnDocumentStart(data?.initializationScripts)
      .onControllerAttached(() => {
        if (data.didInitialLoad === true) {
          return;
        }
        data.didInitialLoad = true;
        const ctrl = data.controller;
        // Set up download delegate after controller is attached
        setupDownloadDelegate(data);
        // Inject controller into PredefinedActionExecutor (edit-menu commands).
        // Mirrors WebviewPlugin.ets; ordered after setupDownloadDelegate (audit fix).
        notifyPrimaryWebviewController(ctrl as ESObject);
        // Set custom User-Agent if provided
        if (data.userAgent) {
          try {
            ctrl.setCustomUserAgent(data.userAgent);
          } catch (error) {
            hilog.error(DOMAIN, 'DefaultWebview', 'setCustomUserAgent failed: %{public}s', JSON.stringify(error));
          }
        }
        if (data?.url) {
          const header: WebHeader[] = Object.keys(
            (data?.headers || {}) as Record<string, string>,
          ).reduce((t: WebHeader[], i) => {
            t.push({ headerKey: i, headerValue: data.headers![i] } as WebHeader);
            return t;
          }, []);
          ctrl.loadUrl(data.url, header);
        } else {
          ctrl.loadData(data!.html, "text/html", "UTF-8", " ", " ");
        }
      })
      .onErrorReceive((event) => {
        hilog.error(DOMAIN, 'DefaultWebview', 'Embedded Web onErrorReceive: %{public}s', JSON.stringify(event));
        if (event.error) {
          if (!event.request.isMainFrame()) {
            hilog.warn(DOMAIN, 'DefaultWebview', 'Embedded sub-resource error ignored, code: %{public}d', event.error.getErrorCode());
            return;
          }
          const ctrl = data.controller;
          const errorCode = event.error.getErrorCode();
          const errorInfo = event.error.getErrorInfo();
          hilog.error(DOMAIN, 'DefaultWebview', 'Embedded Main frame load failed: %{public}d - %{public}s', errorCode, errorInfo);
          const errorHtml = `
            <html>
              <body style="display:flex;justify-content:center;align-items:center;height:100vh;margin:0;background:#f5f5f5;font-family:sans-serif;">
                <div style="text-align:center;padding:20px;">
                  <h2>Network Error</h2>
                  <p>Failed to load the page. Please check your connection.</p>
                  <p style="color:#666;font-size:12px;">Error: ${errorCode} - ${errorInfo}</p>
                </div>
              </body>
            </html>
          `;
          ctrl.loadData(errorHtml, 'text/html', 'UTF-8', ' ', ' ');
        }
      })
      .onLoadIntercept((event) => {
        const url = event.data.getRequestUrl();
        // ArkWeb consumes OS file drops by navigating to file://<dropped file> → white screen.
        // Block it and forward the path via the drag-drop pipe (see WebBuilder onLoadIntercept
        // for full rationale). Safe: the embedding runtime never loads via file://.
        if (url && url.startsWith('file://')) {
          hilog.info(DOMAIN, 'DefaultWebview', 'onLoadIntercept(embedded) file:// drop-consumption blocked: %{public}s', url);
          if (typeof data?.onDragAndDrop === 'function') {
            let path = '';
            try { path = stripDragScheme(decodeURIComponent(url)); } catch (e) { path = stripDragScheme(url); }
            data.onDragAndDrop('drop|' + path + '|0,0');
          }
          return true;
        }
        if (typeof data?.onNavigationRequest === "function") {
          // onLoadIntercept: true = block, false = allow
          // onNavigationRequest: true = allow, false = block
          const ret = data.onNavigationRequest(url);
          return !ret;
        }
        return false;
      })
      .onInterceptRequest((event) => {
        return handleInterceptRequest(data, event as { request: WebResourceRequest });
      })
      .onTitleReceive((e) => {
        if (typeof data?.onTitleChange === "function") {
          data.onTitleChange(e.title);
        }
      })
      .onPageBegin((e) => {
        if (typeof data?.onPageBegin === "function") {
          data.onPageBegin(e.url);
        }
      })
      .onPageEnd((e) => {
        if (typeof data?.onPageEnd === "function") {
          data.onPageEnd(e.url);
        }
      })
      .multiWindowAccess(true)
      .allowWindowOpenMethod(true)
      .onWindowNew((event) => {
        handleWindowNew(event, data, 'EmbeddedWebBuilder');
      })
      // Drag-and-drop: forward to Rust via onDragAndDrop pipe string. See WebBuilder.
      .onDragEnter((dragEvent: DragEvent) => {
        if (data?.dragDropOverlay === true) return;
        if (typeof data?.onDragAndDrop === 'function') { data.onDragAndDrop(buildDragPipe('enter', dragEvent, false)); }
      })
      .onDragMove((dragEvent: DragEvent) => {
        if (data?.dragDropOverlay === true) return;
        if (typeof data?.onDragAndDrop === 'function') { data.onDragAndDrop(buildDragPipe('over', dragEvent, false)); }
      })
      .onDrop((dragEvent: DragEvent) => {
        if (data?.dragDropOverlay === true) return;
        if (typeof data?.onDragAndDrop === 'function') { data.onDragAndDrop(buildDragPipe('drop', dragEvent, true)); }
      })
      .onDragLeave((dragEvent: DragEvent) => {
        if (data?.dragDropOverlay === true) return;
        if (typeof data?.onDragAndDrop === 'function') { data.onDragAndDrop(buildDragPipe('leave', dragEvent, false)); }
      })
      if (data?.dragDropOverlay === true && typeof data?.onDragAndDrop === 'function') {
        Stack()
          .width("100%")
          .height("100%")
          .backgroundColor(Color.Transparent)
          .hitTestBehavior(HitTestMode.Transparent)
          .onDragEnter((dragEvent: DragEvent) => { data.onDragAndDrop(buildDragPipe('enter', dragEvent, false)); })
          .onDragMove((dragEvent: DragEvent) => { data.onDragAndDrop(buildDragPipe('over', dragEvent, false)); })
          .onDrop((dragEvent: DragEvent) => { data.onDragAndDrop(buildDragPipe('drop', dragEvent, true)); })
          .onDragLeave((dragEvent: DragEvent) => { data.onDragAndDrop(buildDragPipe('leave', dragEvent, false)); })
      }
    }
  // Explicit bounds when provided (child webviews); "100%" natural layout
  // otherwise (see WebBuilder). Keeps .position for host-slot placement.
  .width(data.style?.width ?? "100%")
  .height(data.style?.height ?? "100%")
  .position({
    x: data.style?.x ?? 0,
    y: data.style?.y ?? 0,
  })
  .backgroundColor(Color.Transparent)
  .clip(true)
  .visibility(data?.style?.visible === false ? Visibility.Hidden : Visibility.Visible)
  .hitTestBehavior(HitTestMode.Default);
}

const webViewWrap = wrapBuilder<[WebviewNodeData]>(WebBuilder);
const embeddedWebViewWrap = wrapBuilder<[WebviewNodeData]>(EmbeddedWebBuilder);

interface AddWebviewMethod {
  webTag: string;
  controller: JsHelper;
}

export interface EmbeddedWebviewHandle extends AddWebviewMethod {
  content: ComponentContent<WebviewNodeData>;
}

interface EmbeddedWebviewEntry {
  data: WebviewNodeData;
  content: ComponentContent<WebviewNodeData>;
}

function ensureWebviewNodeData(data: WebviewInitData): WebviewNodeData {
  if (!data.webTag) {
    data.webTag = randomString();
  }
  if (!data.controller) {
    data.controller = new web_webview.WebviewController(data.webTag) as WebviewController;
  }
  data.style = data.style || {};
  if (typeof data.javascriptEnable !== "boolean") {
    data.javascriptEnable = true;
  }
  const prepared = data as WebviewNodeData;
  prepared.didInitialLoad = prepared.didInitialLoad === true;
  // Webviews created without explicit style.width follow their parent
  // container ("100%"). Runtime set_bounds width/height is stripped for them
  // in updateWebviewStyle so window resizes keep driving ArkWeb relayout.
  prepared.naturalLayout = prepared.naturalLayout === true || prepared.style.width === undefined;

  if (prepared?.devtools) {
    setWebDebuggingAccess(true);
  }

  return prepared;
}

function setupDownloadDelegate(data: WebviewNodeData) {
  if (typeof data?.onDownloadStart !== "function" && typeof data?.onDownloadEnd !== "function") {
    hilog.info(DOMAIN, 'DefaultWebview', 'setupDownloadDelegate: no download handlers registered');
    return;
  }

  hilog.info(DOMAIN, 'DefaultWebview', 'setupDownloadDelegate: registering download delegate');
  const download = new web_webview.WebDownloadDelegate();

  if (typeof data?.onDownloadStart === "function") {
    download.onBeforeDownload((e) => {
      const url = e.getUrl();
      const tempPath = e.getFullPath();
      hilog.info(DOMAIN, 'DefaultWebview', 'onBeforeDownload → onDownloadStart: %{public}s', url);
      const ret = data.onDownloadStart!(url, tempPath);

      if (ret.allow) {
        e.start(ret.tempPath || tempPath);
      } else {
        e.cancel();
      }
    });
  }

  if (typeof data?.onDownloadEnd === "function") {
    download.onDownloadFinish((e) => {
      const url = e.getUrl();
      const tempPath = e.getFullPath();
      hilog.info(DOMAIN, 'DefaultWebview', 'onDownloadFinish → onDownloadEnd: %{public}s, success=true', url);
      data.onDownloadEnd!(url, tempPath, true);
    });
    download.onDownloadFailed((e) => {
      const url = e.getUrl();
      hilog.info(DOMAIN, 'DefaultWebview', 'onDownloadFailed → onDownloadEnd: %{public}s, success=false', url);
      data.onDownloadEnd!(url, undefined, false);
    });
  }

  data.controller.setDownloadDelegate(download);
}

function buildJsHelper(controller: WebviewController): JsHelper {
  const getUrl = () => {
    return controller.getUrl();
  };
  const getCookiesHelper = (url: string) => {
    return getCookies(url) as string;
  };
  const setCookieHelper = (url: string, value: string) => {
    setCookie(url, value);
  };
  const setWebDebuggingAccessHelper = (enabled: boolean) => {
    setWebDebuggingAccess(enabled);
  };
  const isWebDebuggingAccessHelper = (): boolean => {
    return isWebDebuggingAccess();
  };
  const loadUrl = (url: string, header?: Record<string, string>) => {
    const headers = Object.keys((header || {}) as Record<string, string>).reduce(
      (t, i) => {
        if (!!header![i]) {
          t.push({ headerKey: i, headerValue: header![i] });
        }
        return t;
      },
      [] as Array<WebHeader>,
    );
    controller.loadUrl(url, headers);
  };

  const loadHtml = (html: string) => {
    controller.loadData(html, "text/html", "UTF-8", " ", " ");
  };

  const zoom = (scale: number) => {
    controller.zoom(scale);
  };

  const refresh = () => {
    controller.refresh();
  };

  const requestFocus = () => {
    controller.requestFocus();
  };

  const clearAllBrowsingData = () => {
    web_webview.WebStorage.deleteAllData(true);
    web_webview.WebDataBase.deleteHttpAuthCredentials();
    controller.removeCache(true);
    controller.clearHistory();
  };

  const runJavaScript = (code: string, cb: (result?: string) => void) => {
    controller.runJavaScript(code).then((ret) => {
      cb(ret ?? undefined);
    }).catch((err) => {
      hilog.error(DOMAIN, 'DefaultWebview', 'runJavaScript ERR message=%{public}s code=%{public}s', String(err?.message || err), code.substring(0, 120));
      cb(undefined);
    });
  };

  const webPageSnapshot = (): Promise<SnapshotData> => {
    return new Promise<SnapshotData>((resolve, reject) => {
      // Overall timeout: reject if not completed within 10s
      let settled = false;
      const timeoutId = setTimeout(() => {
        if (!settled) {
          settled = true;
          reject(new Error('webPageSnapshot timed out after 10s'));
        }
      }, 10000);

      const done = (fn: () => void) => {
        if (!settled) {
          settled = true;
          clearTimeout(timeoutId);
          fn();
        }
      };

      const attempt = (retriesLeft: number) => {
        if (settled) return;
        try {
          controller.webPageSnapshot({ id: "snapshot" }, (error: BusinessError, result: web_webview.SnapshotResult) => {
            if (error) {
              if (retriesLeft > 0) {
                hilog.warn(DOMAIN, 'DefaultWebview', 'webPageSnapshot attempt failed (%{public}s), retrying (%{public}d left)...', error.message, retriesLeft);
                setTimeout(() => attempt(retriesLeft - 1), 500);
              } else {
                hilog.error(DOMAIN, 'DefaultWebview', 'webPageSnapshot error: %{public}s', JSON.stringify(error));
                done(() => reject(new Error(`webPageSnapshot failed: ${error.code} - ${error.message}`)));
              }
              return;
            }
            if (!result || result.status !== true || !result.imagePixelMap) {
              done(() => reject(new Error('webPageSnapshot returned empty or failed result')));
              return;
            }
            const pixelMap = result.imagePixelMap;
            try {
              const info = pixelMap.getImageInfoSync();
              const byteCount = pixelMap.getPixelBytesNumber();
              const buffer = new ArrayBuffer(byteCount);
              pixelMap.readPixelsToBufferSync(buffer);
              const rgba = new Uint8Array(buffer);
              done(() => resolve({
                rgba: rgba,
                width: info.size.width,
                height: info.size.height,
              }));
            } catch (e) {
              hilog.error(DOMAIN, 'DefaultWebview', 'webPageSnapshot PixelMap conversion error: %{public}s', String(e));
              done(() => reject(new Error(`PixelMap conversion failed: ${String(e)}`)));
            } finally {
              try {
                pixelMap.release();
              } catch (releaseErr) {
                hilog.warn(DOMAIN, 'DefaultWebview', 'webPageSnapshot PixelMap release warning: %{public}s', String(releaseErr));
              }
            }
          });
        } catch (e) {
          if (retriesLeft > 0) {
            hilog.warn(DOMAIN, 'DefaultWebview', 'webPageSnapshot exception (%{public}s), retrying (%{public}d left)...', String(e), retriesLeft);
            setTimeout(() => attempt(retriesLeft - 1), 500);
          } else {
            hilog.error(DOMAIN, 'DefaultWebview', 'webPageSnapshot exception: %{public}s', String(e));
            done(() => reject(new Error(`webPageSnapshot exception: ${String(e)}`)));
          }
        }
      };
      // Initial delay + up to 3 retries with 500ms intervals
      setTimeout(() => attempt(3), 500);
    });
  };

  const activePdfOps = new Map<string, boolean>();

  const createPdf = (path: string, config: Record<string, number | boolean>, callback: (success: boolean) => void) => {
    // Per-path mutex: prevent concurrent writes to the same file
    if (activePdfOps.has(path)) {
      hilog.warn(DOMAIN, 'DefaultWebview', 'createPdf: operation already in progress for %{public}s', path);
      callback(false);
      return;
    }
    activePdfOps.set(path, true);
    const done = (success: boolean) => { activePdfOps.delete(path); callback(success); };

    // API 14+ guard: createPdf is not available on API 12/13 devices
    if (typeof controller.createPdf !== 'function') {
      hilog.error(DOMAIN, 'DefaultWebview', 'createPdf requires API 14+, not available on this device');
      done(false);
      return;
    }

    // Merge user config with defaults
    const mergedConfig: web_webview.PdfConfiguration = { ...DEFAULT_PDF_CONFIG };
    if (config) {
      if (config['width'] !== undefined) mergedConfig.width = config['width'] as number;
      if (config['height'] !== undefined) mergedConfig.height = config['height'] as number;
      if (config['marginTop'] !== undefined) mergedConfig.marginTop = config['marginTop'] as number;
      if (config['marginBottom'] !== undefined) mergedConfig.marginBottom = config['marginBottom'] as number;
      if (config['marginLeft'] !== undefined) mergedConfig.marginLeft = config['marginLeft'] as number;
      if (config['marginRight'] !== undefined) mergedConfig.marginRight = config['marginRight'] as number;
      if (config['shouldPrintBackground'] !== undefined) mergedConfig.shouldPrintBackground = config['shouldPrintBackground'] as boolean;
      if (config['scale'] !== undefined) mergedConfig.scale = config['scale'] as number;
    }

    controller.createPdf(mergedConfig)
      .then(async (result) => {
        try {
          const buffer = result.pdfArrayBuffer().buffer;
          if (buffer.byteLength === 0) {
            hilog.warn(DOMAIN, 'DefaultWebview', 'createPdf: empty PDF buffer (blank page?)');
            done(false);
            return;
          }
          const file = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
          try {
            await fileIo.write(file.fd, buffer);
            done(true);
          } catch (writeErr) {
            hilog.error(DOMAIN, 'DefaultWebview', 'createPdf write failed: %{public}s', JSON.stringify(writeErr));
            done(false);
          } finally {
            fileIo.closeSync(file);
          }
        } catch (err) {
          hilog.error(DOMAIN, 'DefaultWebview', 'createPdf file IO failed: %{public}s', JSON.stringify(err));
          done(false);
        }
      })
      .catch((err) => {
        hilog.error(DOMAIN, 'DefaultWebview', 'createPdf failed: %{public}s', JSON.stringify(err));
        done(false);
      });
  };
  const printPage = (path: string) => {
    // Generate PDF to `path` via createPdf, then invoke @ohos.print.
    // See ohos-webview-print spec.
    createPdf(path, { shouldPrintBackground: true } as Record<string, number | boolean>, (success: boolean) => {
      if (!success) {
        hilog.error(DOMAIN, 'DefaultWebview', 'print: createPdf failed for %{public}s', path);
        return;
      }
      const cleanup = () => {
        try { fileIo.unlinkSync(path); } catch (e) { /* temp PDF cleanup; ignore if already gone */ }
      };
      try {
        // printKit.print requires file URIs (not absolute paths) + a UIAbilityContext.
        // Convert the sandbox path via fileUri.getUriFromPath, and obtain the
        // UIAbilityContext from the global getContext(). Without the URI conversion
        // print rejects with an opaque "undefined" error (401 param error).
        const fileURI = fileUri.getUriFromPath(path);
        const ctx = getContext() as common.UIAbilityContext;
        if (!ctx) {
          hilog.error(DOMAIN, 'DefaultWebview', 'print: UIAbilityContext unavailable');
          cleanup();
          return;
        }
        hilog.info(DOMAIN, 'DefaultWebview', 'print: invoking printKit.print(uri=%{public}s)', fileURI);
        printKit.print([fileURI], ctx)
          .then((task: printKit.PrintTask) => {
            hilog.info(DOMAIN, 'DefaultWebview', 'print: job submitted, waiting for terminal state');
            // Do NOT cleanup here — printKit.print resolves when the print preview
            // dialog opens, not when printing completes. Deleting the temp PDF now
            // would cause the actual print to fail (file gone). Cleanup on terminal
            // state (succeed/fail/cancel) instead.
            task.on('succeed', () => { hilog.info(DOMAIN, 'DefaultWebview', 'print: succeeded'); cleanup(); });
            task.on('fail', () => { hilog.error(DOMAIN, 'DefaultWebview', 'print: failed'); cleanup(); });
            task.on('cancel', () => { hilog.info(DOMAIN, 'DefaultWebview', 'print: cancelled'); cleanup(); });
          })
          .catch((e: BusinessError) => {
            hilog.error(DOMAIN, 'DefaultWebview', 'print: PrintKit failed: code=%{public}d msg=%{public}s', e.code, e.message);
            cleanup();
          });
      } catch (e) {
        hilog.error(DOMAIN, 'DefaultWebview', 'print: @ohos.print unavailable: %{public}s', JSON.stringify(e));
        cleanup();
      }
    });
  };
  return {
    getUrl,
    getCookies: getCookiesHelper,
    setCookie: setCookieHelper,
    setWebDebuggingAccess: setWebDebuggingAccessHelper,
    isWebDebuggingAccess: isWebDebuggingAccessHelper,
    loadUrl,
    loadHtml,
    zoom,
    refresh,
    requestFocus,
    clearAllBrowsingData,
    runJavaScript,
    webPageSnapshot,
    setBackgroundColor: (_color: number) => {},
    setVisible: (_visible: boolean) => {},
    setBounds: (_x: number, _y: number, _width: number, _height: number) => {},
    setBlurRadius: (_radius: number) => {},
    dispose: () => {},
    createPdf,
    print: printPage,
    registerHttpsIntercept: (_protocols: string[]) => {
      // No-op stub. ArkHelper.ets overrides this on the controller with the
      // real implementation that merges protocols into the per-webview set.
    },
  } as JsHelper;
}

export class RustWebviewNodeController extends NodeController {
  private rootNode: FrameNode | null = null;
  private webviewEntries: Map<string, WebviewNodeData> = new Map();
  private webviewList: Map<string, BuilderNode<[WebviewNodeData]>> = new Map();
  private uiContext: UIContext | null = null;

  constructor(uiContext: UIContext) {
    super();
    this.uiContext = uiContext;
  }

  updateWebviewStyle(webTag: string, style: WebviewStyle) {
    const entry = this.webviewEntries.get(webTag);
    const node = this.webviewList.get(webTag);
    if (!entry || !node) {
      return;
    }

    let effectiveStyle: WebviewStyle = style;
    if (entry.naturalLayout === true) {
      // Natural-layout webviews (created without style.width — the main webview
      // of each window) keep "100%" sizing: tauri-runtime-wry calls set_bounds on
      // every window resize with the new window dims, and applying those as
      // explicit pixels would desync the page layout from the window
      // (BuilderNode.update does not notify ArkWeb to relayout — the 0cac4c3
      // regression). Strip width/height so only position/colors/visibility apply.
      effectiveStyle = { ...style, width: undefined, height: undefined };
    }

    const newEntry: WebviewNodeData = { ...entry, style: effectiveStyle };
    this.webviewEntries.set(webTag, newEntry);
    // Runtime refresh via AttributeUpdater — node.update does not refresh backgroundBlurStyle/backgroundColor,
    // so Acrylic/Mica tints (set_window_background_color) and blur radius need modifier.attribute to
    // trigger an immediate component update.
    if (entry.blurModifier) {
      if (style.backgroundColor !== undefined && style.backgroundColor !== null) {
        entry.blurModifier.attribute?.backgroundColor(style.backgroundColor);
      }
      if (style.blurRadius !== undefined) {
        entry.blurModifier.applyBlur(style.blurRadius);
      }
    }
    node.update(newEntry);
  }

  /**
   * Update blur radius for all webviews managed by this controller.
   * Called by WindowManager.setWindowBlur() to apply window-level blur effect.
   * Uses BlurModifier.applyBlur() which selects the correct API based on
   * the window's transparent flag (backgroundBlurStyle vs backdropBlur).
   */
  setAllWebviewsBlurRadius(radius: number): void {
    hilog.info(DOMAIN, 'DefaultWebview', '[DBG] setAllWebviewsBlurRadius: radius=%{public}d entries=%{public}d', radius, this.webviewEntries.size);
    for (const [webTag, entry] of this.webviewEntries) {
      // Runtime refresh via AttributeUpdater — BuilderNode.update does not refresh blur attributes.
      // applyBlur() selects the correct API: backgroundBlurStyle (transparent) or backdropBlur (opaque).
      if (entry.blurModifier) {
        entry.blurModifier.applyBlur(radius);
      }
      // Keep style.blurRadius in sync so any subsequent re-build preserves the value.
      if (!entry.style) {
        entry.style = {};
      }
      entry.style.blurRadius = radius;
    }
  }

  private buildData(controller: WebviewController) {
    return buildJsHelper(controller);
  }

  makeNode(uiContext: UIContext): FrameNode {
    if (this.rootNode === null) {
      this.rootNode = new FrameNode(uiContext);
    }
    return this.rootNode;
  }

  addWebview(data: WebviewInitData): AddWebviewMethod {
    // Pass UIContext for promptAction (e.g., openNewWindowDialog)
    if (!data.uiContext && this.uiContext) {
      data.uiContext = this.uiContext;
    }
    const prepared = ensureWebviewNodeData(data);
    if (!prepared.blurModifier) {
      prepared.blurModifier = new BlurModifier();
    }
    // Wire transparent flag so runtime applyBlur() selects the correct blur API.
    prepared.blurModifier.transparent = data.transparent === true;
    hilog.info(DOMAIN, 'DefaultWebview', '[DBG] addWebview: webTag=%{public}s transparent=%{public}s blurRadius=%{public}d',
      prepared.webTag ?? '?', String(data.transparent), data.style?.blurRadius ?? 0);
    const webTag = prepared.webTag!;
    if (this.rootNode === null) {
      this.rootNode = new FrameNode(this.uiContext!);
    }

    const node = new BuilderNode<[WebviewNodeData]>(this.uiContext!);
    node.build(webViewWrap, prepared);

    const controller = this.buildData(prepared.controller);
    this.webviewEntries.set(webTag, prepared);
    this.webviewList.set(webTag, node);

    this.rootNode?.appendChild(node.getFrameNode());

    return {
      webTag,
      controller,
    };
  }

  removeWebview(webTag: string) {
    const node = this.webviewList.get(webTag);
    if (!node) {
      return;
    }

    this.webviewEntries.delete(webTag);
    this.webviewList.delete(webTag);

    this.rootNode?.removeChild(node.getFrameNode());
  }

  getPrimaryWebviewController(): web_webview.WebviewController | null {
    const firstEntry = this.webviewEntries.values().next().value;
    return (firstEntry as WebviewNodeData)?.controller ?? null;
  }
}

export class EmbeddedWebviewManager {
  private uiContext: UIContext;
  private entries: Map<string, EmbeddedWebviewEntry> = new Map();

  constructor(uiContext: UIContext) {
    this.uiContext = uiContext;
  }

  createWebview(data: WebviewInitData): EmbeddedWebviewHandle {
    // Pass UIContext for promptAction (e.g., openNewWindowDialog)
    if (!data.uiContext) {
      data.uiContext = this.uiContext;
    }
    const prepared = ensureWebviewNodeData(data);
    const webTag = prepared.webTag!;

    const content = new ComponentContent<WebviewNodeData>(
      this.uiContext,
      embeddedWebViewWrap,
      prepared,
    );

    content.update(prepared);

    const controller = buildJsHelper(prepared.controller);
    this.entries.set(webTag, {
      data: prepared,
      content,
    });

    return {
      webTag,
      controller,
      content,
    };
  }

  updateWebviewStyle(webTag: string, style: WebviewStyle) {
    const entry = this.entries.get(webTag);
    if (!entry) {
      return;
    }

    let effectiveStyle: WebviewStyle = style;
    if (entry.data.naturalLayout === true) {
      // See RustWebviewNodeController.updateWebviewStyle (naturalLayout guard).
      effectiveStyle = { ...style, width: undefined, height: undefined };
    }

    const newData: WebviewNodeData = { ...entry.data, style: effectiveStyle };
    entry.data = newData;
    entry.content.update(newData);
  }

  /**
   * Update blur radius for all embedded webviews managed by this manager.
   * NOTE: EmbeddedWebBuilder does not attach a BlurModifier and content.update does not refresh
   * backgroundBlurStyle, so this is a no-op. Vibrancy is only supported via RustWebviewNodeController
   * (WebBuilder path). Kept as no-op to satisfy the controller interface.
   */
  setAllWebviewsBlurRadius(_radius: number): void {
    // No-op: embedded webviews do not support runtime backgroundBlurStyle refresh.
  }

  removeWebview(webTag: string) {
    const entry = this.entries.get(webTag);
    if (!entry) {
      return;
    }

    this.entries.delete(webTag);
    entry.content.dispose();
  }
}

// extend WebviewController method
declare class WebviewController extends web_webview.WebviewController {
  getCookies: (url: string) => string;
  setBackgroundColor: (color: number) => void;
  setVisible: (visible: boolean) => void;
  setBounds: (x: number, y: number, width: number, height: number) => void;
  setBlurRadius: (radius: number) => void;
  dispose: () => void;
  clearAllBrowsingData: () => void;
}
