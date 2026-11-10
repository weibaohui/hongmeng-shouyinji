import { AbilityConstant, UIAbility, Want, common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { RadioService } from '../player/RadioService';

const DOMAIN: number = 0x0000;
const TAG: string = 'Radio';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Radio ability onCreate');
    // 播控中心会话与长时任务都在这里建立：Ability 是唯一允许申请长时任务的载体。
    const ctx: common.UIAbilityContext = this.context as common.UIAbilityContext;
    RadioService.getInstance().attach(ctx);
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
        return;
      }
      try {
        windowStage.getMainWindowSync().setWindowLayoutFullScreen(true);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'setWindowLayoutFullScreen failed');
      }
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, 'Radio ability onWindowStageDestroy');
  }

  onDestroy(): void {
    // Ability 真正销毁才释放播放器；退到后台（onBackground）不会走到这里，
    // 所以后台播放不受影响。
    RadioService.getInstance().release();
    hilog.info(DOMAIN, TAG, 'Radio ability onDestroy');
  }
}
