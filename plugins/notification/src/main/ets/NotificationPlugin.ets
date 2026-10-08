import wantAgent, { WantAgent } from "@ohos.app.ability.wantAgent";
import notificationManager from "@ohos.notificationManager";
import {
  AsyncPluginBase,
  BridgeCallContext,
  BridgeContextRequirement,
  BridgeTypedValue,
  expectBridgeRequestType,
} from "@ohos-rs/ability";

const SHOW_REQUEST_TYPE = "ohos.notification.ShowRequest";
const DISMISS_REQUEST_TYPE = "ohos.notification.DismissRequest";
const ACKNOWLEDGEMENT_TYPE = "ohos.notification.Acknowledgement";

interface NotificationAction {
  id: string;
  label: string;
}

interface ShowRequest {
  tag: string;
  title: string;
  body: string;
  actions: NotificationAction[];
}

interface DismissRequest {
  tag: string;
}

class NotificationAcknowledgement {
  readonly accepted: boolean;

  constructor(accepted: boolean) {
    this.accepted = accepted;
  }
}

// The URI is delivered to NativeAbility.onNewWant when the notification is tapped.
function responseUri(tag: string, actionId?: string): string {
  const query = `tag=${encodeURIComponent(tag)}`;
  return (
    `gpui-notification://response?${query}` +
    (actionId === undefined ? "" : `&action=${encodeURIComponent(actionId)}`)
  );
}

function requestCode(uri: string): number {
  let hash = 2166136261;
  for (let index = 0; index < uri.length; index++) {
    hash = Math.imul(hash ^ uri.charCodeAt(index), 16777619);
  }
  return hash & 0x7fffffff;
}

function notificationLabel(tag: string): string {
  return `${requestCode(tag)}:${requestCode(tag + "#")}`;
}

export class NotificationPlugin extends AsyncPluginBase {
  readonly id = "ohos.notification";
  readonly requires: BridgeContextRequirement[] = ["ability"];

  async invokeAsync(
    action: string,
    payload: BridgeTypedValue,
    context: BridgeCallContext,
  ): Promise<BridgeTypedValue> {
    if (!context.isActive()) {
      throw new Error("Notification bridge session is no longer active");
    }
    if (action === "show") {
      const request = expectBridgeRequestType(
        payload,
        this.id,
        action,
        SHOW_REQUEST_TYPE,
      ) as ShowRequest;
      if (!request.tag || !request.title || !request.body || !Array.isArray(request.actions)) {
        throw new Error("Notification requires a tag, title, body and actions array");
      }
      if (!(await notificationManager.isNotificationEnabled())) {
        await notificationManager.requestEnableNotification(context.abilityContext);
      }
      if (!context.isActive()) {
        throw new Error("Notification bridge session ended during authorization");
      }
      const abilityInfo = context.abilityContext.abilityInfo;
      const agentFor = async (uri: string): Promise<WantAgent> => {
        return wantAgent.getWantAgent({
          wants: [
            {
              bundleName: abilityInfo.bundleName,
              abilityName: abilityInfo.name,
              uri,
            },
          ],
          actionType: wantAgent.OperationType.START_ABILITY,
          requestCode: requestCode(uri),
          actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG],
        });
      };
      const buttons: notificationManager.NotificationActionButton[] = [];
      for (const item of request.actions.slice(0, 3)) {
        if (!item.id || !item.label) {
          throw new Error("Notification actions require an id and label");
        }
        buttons.push({
          title: item.label,
          wantAgent: await agentFor(responseUri(request.tag, item.id)),
        });
      }
      const notification: notificationManager.NotificationRequest = {
        id: requestCode(request.tag),
        label: notificationLabel(request.tag),
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: { title: request.title, text: request.body },
        },
        wantAgent: await agentFor(responseUri(request.tag)),
        actionButtons: buttons,
      };
      await notificationManager.publish(notification);
      return { typeName: ACKNOWLEDGEMENT_TYPE, value: new NotificationAcknowledgement(true) };
    }
    if (action === "dismiss") {
      const request = expectBridgeRequestType(
        payload,
        this.id,
        action,
        DISMISS_REQUEST_TYPE,
      ) as DismissRequest;
      if (!request.tag) {
        throw new Error("Notification tag must be non-empty");
      }
      await notificationManager.cancel(requestCode(request.tag), notificationLabel(request.tag));
      return { typeName: ACKNOWLEDGEMENT_TYPE, value: new NotificationAcknowledgement(true) };
    }
    throw new Error(`Unsupported ${this.id} action '${action}'`);
  }
}
