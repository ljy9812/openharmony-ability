import { ComponentContent, UIContext } from "@kit.ArkUI";
import { BridgeCallContext } from "@ohos-rs/ability";

export interface WindowPromptRequest {
  windowId: number;
  message: string;
  detail?: string;
  level: number;
  buttons: string[];
  cancelIndex?: number;
  anchor?: WindowPromptAnchor;
}
export interface WindowPromptAnchor {
  x: number;
  y: number;
}

class PromptModel {
  readonly request: WindowPromptRequest;
  readonly choose: (index: number) => void;
  constructor(request: WindowPromptRequest, choose: (index: number) => void) {
    this.request = request;
    this.choose = choose;
  }
}

@Builder
function promptBuilder(model: PromptModel) {
  Column({ space: 12 }) {
    Text(model.request.message)
      .fontSize(20)
      .fontWeight(FontWeight.Medium)
      .fontColor($r("sys.color.font_primary"))
      .width("100%")
    if (model.request.detail) {
      Text(model.request.detail)
        .fontSize(14)
        .fontColor($r("sys.color.font_secondary"))
        .width("100%");
    }
    Scroll() {
      Column({ space: 8 }) {
        ForEach(model.request.buttons, (label: string, index: number) => {
          Button(label)
            .width("100%")
            .onClick(() => model.choose(index));
        })
      }
    }
    .constraintSize({ maxHeight: 360 })
    .width("100%")
  }
  .padding(24)
  .width(model.request.anchor ? 240 : 400)
  .constraintSize({ maxWidth: "90%" })
  .backgroundColor($r("sys.color.comp_background_primary"))
  .borderRadius(16);
}

/** One dialog lifetime; only ArkTS owns the ComponentContent and UIContext. */
class PromptSession {
  private readonly uiContext: UIContext;
  private readonly request: WindowPromptRequest;
  private readonly context: BridgeCallContext;
  private content?: ComponentContent<PromptModel>;
  private completed: boolean = false;
  private opened: boolean = false;
  private closing?: Promise<void>;
  private unsubscribe?: () => void;
  private resolve?: (index: number) => void;
  private reject?: (error: Error) => void;

  constructor(uiContext: UIContext, request: WindowPromptRequest, context: BridgeCallContext) {
    this.uiContext = uiContext;
    this.request = request;
    this.context = context;
  }

  async run(): Promise<number> {
    const result = new Promise<number>((resolve, reject) => {
      this.resolve = resolve;
      this.reject = reject;
    });
    // An open failure or cancellation can reject before openCustomDialog completes.
    void result.catch(() => {});
    // Register cancellation before building/opening: a late open must be closed again.
    this.unsubscribe = this.context.onCancel(() => {
      void this.cancel();
    });
    try {
      const model = new PromptModel(this.request, (index: number): void => {
        void this.choose(index);
      });
      const content = new ComponentContent(this.uiContext, wrapBuilder(promptBuilder), model);
      this.content = content;
      if (this.completed || !this.context.isActive()) {
        await this.cancel();
      } else {
        await this.uiContext.getPromptAction().openCustomDialog(content, {
          isModal: true,
          autoCancel: this.request.cancelIndex !== undefined && this.request.cancelIndex !== null,
          alignment: this.request.anchor ? DialogAlignment.TopStart : DialogAlignment.Center,
          offset: this.request.anchor
            ? { dx: this.request.anchor.x, dy: this.request.anchor.y }
            : { dx: 0, dy: 0 },
          onDidDisappear: (): void => {
            void this.cancel();
          },
          onWillDismiss: (action: DismissDialogAction): void => {
            if (this.completed) {
              action.dismiss();
            } else if (
              this.request.cancelIndex !== undefined &&
              this.request.cancelIndex !== null
            ) {
              action.dismiss();
              void this.choose(this.request.cancelIndex);
            }
          },
        });
        this.opened = true;
        if (this.completed || !this.context.isActive()) {
          await this.close();
        }
      }
    } catch (error) {
      if (!this.completed) {
        this.completed = true;
        this.reject?.(new Error(`Native prompt failed: ${String(error)}`));
      }
    }
    try {
      return await result;
    } finally {
      this.unsubscribe?.();
      await this.close();
    }
  }

  private async choose(index: number): Promise<void> {
    if (this.completed) {
      return;
    }
    this.completed = true;
    await this.close();
    this.resolve?.(index);
  }

  async cancel(): Promise<void> {
    if (!this.completed) {
      this.completed = true;
      this.reject?.(new Error("Native prompt was cancelled by window/session teardown"));
    }
    await this.close();
  }

  private async close(): Promise<void> {
    if (this.closing) {
      await this.closing;
      return;
    }
    const content = this.content;
    if (this.opened && content) {
      this.opened = false;
      this.closing = this.closeOpened(content);
      await this.closing;
    }
  }

  private async closeOpened(content: ComponentContent<PromptModel>): Promise<void> {
    try {
      await this.uiContext.getPromptAction().closeCustomDialog(content);
    } catch {}
  }

  disposeContent(): void {
    this.content?.dispose();
    this.content = undefined;
  }
}

export class PromptDialogs {
  private readonly sessions: Set<PromptSession> = new Set();

  async show(
    uiContext: UIContext,
    request: WindowPromptRequest,
    context: BridgeCallContext,
  ): Promise<number> {
    if (
      (request.anchor &&
        (!Number.isFinite(request.anchor.x) ||
          !Number.isFinite(request.anchor.y) ||
          request.anchor.x < 0 ||
          request.anchor.y < 0)) ||
      typeof request.message !== "string" ||
      !Number.isInteger(request.level) ||
      request.level < 0 ||
      request.level > 2 ||
      !Array.isArray(request.buttons) ||
      request.buttons.length === 0 ||
      request.buttons.length > 128 ||
      request.buttons.some(
        (label: string) => typeof label !== "string" || label.trim().length === 0,
      ) ||
      (request.cancelIndex !== undefined &&
        request.cancelIndex !== null &&
        (!Number.isInteger(request.cancelIndex) ||
          request.cancelIndex < 0 ||
          request.cancelIndex >= request.buttons.length))
    ) {
      throw new Error("Invalid native prompt request");
    }
    const session = new PromptSession(uiContext, request, context);
    this.sessions.add(session);
    try {
      return await session.run();
    } finally {
      this.sessions.delete(session);
      session.disposeContent();
    }
  }

  async dispose(): Promise<void> {
    const sessions = Array.from(this.sessions);
    this.sessions.clear();
    await Promise.all(sessions.map((session: PromptSession) => session.cancel()));
  }
}
