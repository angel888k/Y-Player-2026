@testable import CatVodUI
import Foundation
import Testing

/// 画面层的「内容盒」（M28 首验之十九）：系统 / 自研内核的强制比例 = 盒 + `resize` —— 纯函数，有单测。
@Suite("画面层：内容盒")
struct LayerContentBoxTests {
    @Test("nil = 铺满（适应 / 裁剪 / 拉伸走 gravity 自己留边）")
    func fill() {
        let rect = LayerContentBox.rect(in: CGSize(width: 402, height: 226.125), aspect: nil)
        #expect(rect == CGRect(x: 0, y: 0, width: 402, height: 226.125))
    }

    @Test("比区还宽的目标：宽顶满、上下居中留边（400×300 里放 2:1）")
    func widerThanContainer() {
        let rect = LayerContentBox.rect(in: CGSize(width: 400, height: 300), aspect: 2)
        #expect(rect == CGRect(x: 0, y: 50, width: 400, height: 200))
    }

    @Test("比区还高的目标：高顶满、左右居中留边（400×300 里放 1:1）")
    func tallerThanContainer() {
        let rect = LayerContentBox.rect(in: CGSize(width: 400, height: 300), aspect: 1)
        #expect(rect == CGRect(x: 50, y: 0, width: 300, height: 300))
    }

    @Test("例外输入退回铺满（aspect ≤ 0 / 空尺寸）")
    func invalidFallsBackToFill() {
        let zeroWidth = LayerContentBox.rect(in: CGSize(width: 0, height: 300), aspect: 2)
        #expect(zeroWidth == CGRect(x: 0, y: 0, width: 0, height: 300))
        let negative = LayerContentBox.rect(in: CGSize(width: 400, height: 300), aspect: -1)
        #expect(negative == CGRect(x: 0, y: 0, width: 400, height: 300))
    }
}
