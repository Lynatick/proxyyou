package balancer

import (
 "testing"
 "time"
 "github.com/sagernet/sing-box/adapter"
 "github.com/sagernet/sing-box/option"
)

func TestVerificationStickyFallbackCannotReturnUncheckedSlowCandidate(t *testing.T) {
 // One attempt forces the fallback branch deterministically, without relying on
 // a lucky hash or changing the production random source.
 source:=pool(StrategyStickySessions,"a","b")
 strategy:=NewStickySession(source.outbounds,option.BalancerOutboundOptions{MaxRetry:1,DelayAcceptableRatio:2})
 strategy.UpdateOutboundsInfo(map[string]*adapter.URLTestHistory{"a":{Time:time.Now(),Delay:400},"b":{Time:time.Now(),Delay:20}})
 for n:=0;n<1000;n++{next:=strategy.Select(adapter.InboundContext{},"tcp",true);if next==nil||next.Tag()!="b"{t.Fatal("unchecked candidate",next)}}
}
