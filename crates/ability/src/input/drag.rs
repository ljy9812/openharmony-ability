//! Native drag handles stay on the UI thread. Callback input is copied before delivery.
use crate::OpenHarmonyWaker;
use ohos_arkui_binding::{component::attribute::ArkUIAttributeBasic, XComponent};
use ohos_arkui_sys as ark;
use ohos_udmf_sys as udmf;
use std::{
    ffi::{c_void, CStr, CString},
    ptr::{self, NonNull},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
};

#[link(name = "pixelmap")]
unsafe extern "C" {
    fn OH_PixelmapInitializationOptions_Create(options: *mut *mut c_void) -> i32;
    fn OH_PixelmapInitializationOptions_SetWidth(options: *mut c_void, width: u32) -> i32;
    fn OH_PixelmapInitializationOptions_SetHeight(options: *mut c_void, height: u32) -> i32;
    fn OH_PixelmapInitializationOptions_SetPixelFormat(options: *mut c_void, format: i32) -> i32;
    fn OH_PixelmapInitializationOptions_SetAlphaType(options: *mut c_void, alpha: i32) -> i32;
    fn OH_PixelmapInitializationOptions_Release(options: *mut c_void) -> i32;
    fn OH_PixelmapNative_CreatePixelmap(
        data: *mut u8,
        length: usize,
        options: *mut c_void,
        pixelmap: *mut *mut c_void,
    ) -> i32;
    fn OH_PixelmapNative_Release(pixelmap: *mut c_void) -> i32;
}

struct DragPreview {
    pixelmap: NonNull<c_void>,
    _pixels: Vec<u8>,
}
impl DragPreview {
    fn new() -> Result<Self, String> {
        let mut options = ptr::null_mut();
        unsafe {
            check(
                OH_PixelmapInitializationOptions_Create(&mut options),
                "CreateDragPreviewOptions",
            )?
        };
        let options = NonNull::new(options).ok_or("Drag preview options allocation failed")?;
        let result = (|| unsafe {
            check(
                OH_PixelmapInitializationOptions_SetWidth(options.as_ptr(), 32),
                "SetDragPreviewWidth",
            )?;
            check(
                OH_PixelmapInitializationOptions_SetHeight(options.as_ptr(), 32),
                "SetDragPreviewHeight",
            )?;
            check(
                OH_PixelmapInitializationOptions_SetPixelFormat(options.as_ptr(), 4),
                "SetDragPreviewFormat",
            )?;
            check(
                OH_PixelmapInitializationOptions_SetAlphaType(options.as_ptr(), 1),
                "SetDragPreviewAlpha",
            )?;
            let mut pixels = vec![0u8; 32 * 32 * 4];
            for pixel in pixels.as_chunks_mut::<4>().0 {
                pixel.copy_from_slice(&[0x55, 0xc7, 0x3c, 0xff]);
            }
            let mut pixelmap = ptr::null_mut();
            check(
                OH_PixelmapNative_CreatePixelmap(
                    pixels.as_mut_ptr(),
                    pixels.len(),
                    options.as_ptr(),
                    &mut pixelmap,
                ),
                "CreateDragPreviewPixelmap",
            )?;
            let pixelmap =
                NonNull::new(pixelmap).ok_or("Drag preview pixelmap allocation failed")?;
            Ok(Self {
                pixelmap,
                _pixels: pixels,
            })
        })();
        unsafe { OH_PixelmapInitializationOptions_Release(options.as_ptr()) };
        result
    }
}
impl Drop for DragPreview {
    fn drop(&mut self) {
        unsafe { OH_PixelmapNative_Release(self.pixelmap.as_ptr()) };
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DragPhase {
    Enter,
    Move,
    Leave,
    Drop,
}

#[derive(Clone, Debug, Default)]
pub struct DragResponse(Arc<AtomicBool>);
impl DragResponse {
    pub fn accept(&self) {
        self.0.store(true, Ordering::Release);
    }
    pub fn accepted(&self) -> bool {
        self.0.load(Ordering::Acquire)
    }
}
impl PartialEq for DragResponse {
    fn eq(&self, other: &Self) -> bool {
        Arc::ptr_eq(&self.0, &other.0)
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct DragInputData {
    pub phase: DragPhase,
    /// Position in physical pixels relative to the window, including native content offsets.
    pub window_x: f32,
    pub window_y: f32,
    pub file_uris: Vec<String>,
    pub response: DragResponse,
}

struct UnifiedData(NonNull<udmf::OH_UdmfData>);
impl UnifiedData {
    fn new() -> Result<Self, String> {
        NonNull::new(unsafe { udmf::OH_UdmfData_Create() })
            .map(Self)
            .ok_or_else(|| "UDMF allocation failed".into())
    }
}
impl Drop for UnifiedData {
    fn drop(&mut self) {
        unsafe { udmf::OH_UdmfData_Destroy(self.0.as_ptr()) };
    }
}
struct FileUri(NonNull<udmf::OH_UdsFileUri>);
impl FileUri {
    fn new() -> Result<Self, String> {
        NonNull::new(unsafe { udmf::OH_UdsFileUri_Create() })
            .map(Self)
            .ok_or_else(|| "UDMF file URI allocation failed".into())
    }
}
impl Drop for FileUri {
    fn drop(&mut self) {
        unsafe { udmf::OH_UdsFileUri_Destroy(self.0.as_ptr()) };
    }
}
struct Record(NonNull<udmf::OH_UdmfRecord>);
impl Drop for Record {
    fn drop(&mut self) {
        unsafe { udmf::OH_UdmfRecord_Destroy(self.0.as_ptr()) };
    }
}
fn check(code: i32, operation: &str) -> Result<(), String> {
    if code == 0 {
        Ok(())
    } else {
        Err(format!("{operation} failed ({code})"))
    }
}

/// Only called while the ArkUI callback owns `event`. No raw handle escapes this function.
pub(crate) unsafe fn snapshot(event: *mut ark::ArkUI_DragEvent, phase: DragPhase) -> DragInputData {
    let mut file_uris = Vec::new();
    if matches!(phase, DragPhase::Enter | DragPhase::Drop) {
        if let Ok(data) = UnifiedData::new() {
            if ark::OH_ArkUI_DragEvent_GetUdmfData(event, data.0.as_ptr().cast()) == 0 {
                let mut count = 0;
                let records = udmf::OH_UdmfData_GetRecords(data.0.as_ptr(), &mut count);
                // GetRecords returns data-owned record handles. Destroy only the enclosing data.
                if !records.is_null() && count <= 512 {
                    for &record in std::slice::from_raw_parts(records, count as usize) {
                        if record.is_null() {
                            continue;
                        }
                        let Ok(uri) = FileUri::new() else {
                            break;
                        };
                        if udmf::OH_UdmfRecord_GetFileUri(record, uri.0.as_ptr()) != 0 {
                            continue;
                        }
                        let value = udmf::OH_UdsFileUri_GetFileUri(uri.0.as_ptr());
                        if value.is_null() {
                            continue;
                        }
                        if let Ok(value) = CStr::from_ptr(value).to_str() {
                            if value.starts_with("file://")
                                && !file_uris.iter().any(|item| item == value)
                            {
                                file_uris.push(value.to_owned());
                            }
                        }
                    }
                }
            }
        }
    }
    DragInputData {
        phase,
        window_x: ark::OH_ArkUI_DragEvent_GetTouchPointXToWindow(event),
        window_y: ark::OH_ArkUI_DragEvent_GetTouchPointYToWindow(event),
        file_uris,
        response: DragResponse::default(),
    }
}

struct DragCompletion {
    ended: AtomicBool,
    waker: OpenHarmonyWaker,
}
unsafe extern "C" fn drag_status(info: *mut ark::ArkUI_DragAndDropInfo, user: *mut c_void) {
    if info.is_null() || user.is_null() {
        return;
    }
    let status = ark::OH_ArkUI_DragAndDropInfo_GetDragStatus(info);
    crate::info!("OHOS native file drag status: {status}");
    if status == ark::ArkUI_DragStatus_ARKUI_DRAG_STATUS_ENDED {
        let context = &*user.cast::<DragCompletion>();
        context.ended.store(true, Ordering::Release);
        context.waker.wake();
    }
}

/// UI-thread owner of an outbound native drag. Drop unregisters callbacks before freeing their data.
/// The node owner must keep this alive until drag end and drop it before its surface is destroyed.
pub struct NativeFileDrag {
    action: NonNull<ark::ArkUI_DragAction>,
    completion: Box<DragCompletion>,
    _preview: DragPreview,
    _data: UnifiedData,
    _records: Vec<Record>,
    _uris: Vec<FileUri>,
}
impl NativeFileDrag {
    /// Capture the ArkUI node while the component owner is retained, then release
    /// the app's surface lock before starting a drag (which reenters ArkUI).
    pub fn node_handle(component: &XComponent) -> *mut c_void {
        component.raw().raw_handle().cast()
    }

    pub fn start(
        node: *mut c_void,
        pointer_id: i32,
        files: &[(String, bool)],
        waker: OpenHarmonyWaker,
    ) -> Result<Self, String> {
        if files.is_empty() || files.len() > 512 {
            return Err("Native drag requires 1..512 files".into());
        }
        let data = UnifiedData::new()?;
        let mut records = Vec::with_capacity(files.len());
        let mut uris = Vec::with_capacity(files.len());
        for (value, directory) in files {
            if !value.starts_with("file://") {
                return Err("Native drag requires file:// URIs".into());
            }
            let value = CString::new(value.as_str()).map_err(|_| "File URI contains NUL")?;
            let uri = FileUri::new()?;
            let record = Record(
                NonNull::new(unsafe { udmf::OH_UdmfRecord_Create() })
                    .ok_or("UDMF record allocation failed")?,
            );
            unsafe {
                check(
                    udmf::OH_UdsFileUri_SetFileUri(uri.0.as_ptr(), value.as_ptr()),
                    "SetFileUri",
                )?;
                let file_type = if *directory {
                    b"general.folder\0".as_slice()
                } else {
                    b"general.file\0".as_slice()
                };
                check(
                    udmf::OH_UdsFileUri_SetFileType(uri.0.as_ptr(), file_type.as_ptr().cast()),
                    "SetFileType",
                )?;
                check(
                    udmf::OH_UdmfRecord_AddFileUri(record.0.as_ptr(), uri.0.as_ptr()),
                    "AddFileUri",
                )?;
                check(
                    udmf::OH_UdmfData_AddRecord(data.0.as_ptr(), record.0.as_ptr()),
                    "AddRecord",
                )?;
            }
            records.push(record);
            uris.push(uri);
        }
        let preview = DragPreview::new()?;
        let action = NonNull::new(unsafe { ark::OH_ArkUI_CreateDragActionWithNode(node.cast()) })
            .ok_or("DragAction allocation failed")?;
        let mut session = Self {
            action,
            completion: Box::new(DragCompletion {
                ended: AtomicBool::new(false),
                waker,
            }),
            _preview: preview,
            _data: data,
            _records: records,
            _uris: uris,
        };
        unsafe {
            let mut pixelmaps = [session._preview.pixelmap.as_ptr()];
            check(
                ark::OH_ArkUI_DragAction_SetPixelMaps(
                    action.as_ptr(),
                    pixelmaps.as_mut_ptr().cast(),
                    1,
                ),
                "SetDragPreview",
            )?;
            check(
                ark::OH_ArkUI_DragAction_SetPointerId(action.as_ptr(), pointer_id),
                "SetPointerId",
            )?;
            check(
                ark::OH_ArkUI_DragAction_SetData(action.as_ptr(), session._data.0.as_ptr().cast()),
                "SetDragData",
            )?;
            check(
                ark::OH_ArkUI_DragAction_RegisterStatusListener(
                    action.as_ptr(),
                    (&mut *session.completion as *mut DragCompletion).cast(),
                    Some(drag_status),
                ),
                "RegisterDragStatus",
            )?;
            crate::info!("OHOS starting native file drag action");
            check(ark::OH_ArkUI_StartDrag(action.as_ptr()), "StartDrag")?;
            crate::info!("OHOS native file drag action returned");
        }
        Ok(session)
    }
    pub fn ended(&self) -> bool {
        self.completion.ended.load(Ordering::Acquire)
    }
}
impl Drop for NativeFileDrag {
    fn drop(&mut self) {
        crate::info!("OHOS disposing native file drag action");
        unsafe {
            ark::OH_ArkUI_DragAction_UnregisterStatusListener(self.action.as_ptr());
            ark::OH_ArkUI_DragAction_Dispose(self.action.as_ptr());
        }
    }
}
