import Foundation
import KubbRenderer
import Testing

@Suite struct OnlineTests {
  @Test func pitchLinksHaveOneEntryPoint() {
    let link = PitchLink("  MAPKUBB2\n")
    #expect(link?.code == "mapkubb2")
    #expect(link == PitchLink("https://throwingwood.com/p/mapkubb2?from=share"))
    #expect(link == PitchLink("https://kubb.thingelstad.xyz/p/mapkubb2"))
    #expect(link?.url.absoluteString == "https://throwingwood.com/p/mapkubb2")
    let host = "throwingwood.com"
    for s in [
      "", "undefined", "mapkubb0", "https://throwingwood.com.evil/p/mapkubb2",
      "http://kubb.thingelstad.xyz/p/mapkubb2", "https://kubb.thingelstad.xyz/e/mapkubb2",
      "https://throwingwood.com/p/mapkubb2/extra", "https://example.com/p/mapkubb2",
      "https://user@\(host)/p/mapkubb2", "https://throwingwood.com:42/p/mapkubb2",
    ] {
      #expect(PitchLink(s) == nil)
    }
    let fresh = PitchLink.fresh()
    #expect(fresh.code.utf8.count == 10)
    #expect(PitchLink(fresh.url.absoluteString) == fresh)
  }
}
