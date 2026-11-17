//@ args = '--outline-memory'
//@ wasmtime-flags = '-Wcomponent-model-async'

package export_wit_world

import (
	"fmt"
	api "wit_component/test_outlined_memory_api"
	mirror "wit_component/test_outlined_memory_mirror"

	. "go.bytecodealliance.org/pkg/wit/types"
)

func batch(seed uint32) api.Batch {
	tx, rx := api.MakeStreamU8()
	fx, fr := api.MakeFutureU32()
	go func() {
		defer tx.Drop()
		defer fx.Drop()
		tx.WriteAll([]uint8{uint8(seed % 251)})
		fx.Write(seed + 42)
	}()
	return api.Batch{
		Prefix: 0x1234,
		Optional: Some(api.MakeEntryValue(api.Packet{
			Marker: 11, Label: "left",
			Tokens: []*api.Token{api.MakeToken(seed), api.MakeToken(seed + 1)},
			Tail:   0x123456789abcdef0,
		})),
		Outcome: Ok[api.Entry, uint32](api.MakeEntryValue(api.Packet{
			Marker: 29, Label: "right",
			Tokens: []*api.Token{api.MakeToken(seed + 5)},
			Tail:   0xfedcba9876543210,
		})),
		Channel:  Some(rx),
		Deferred: Some(fr),
		Suffix:   0x89abcdef,
	}
}

func check(value api.Batch, seed uint32) {
	assertEqual(value.Prefix, 0x1234)
	assertEqual(value.Suffix, 0x89abcdef)
	stream := value.Channel.Some()
	buffer := make([]uint8, 1)
	assertEqual(stream.Read(buffer), 1)
	assertEqual(buffer[0], uint8(seed%251))
	stream.Drop()
	future := value.Deferred.Some()
	assertEqual(future.Read(), seed+42)
	future.Drop()
	left := value.Optional.Some().Value()
	right := value.Outcome.Ok().Value()
	assertEqual(left.Marker, 11)
	assertEqual(left.Label, "left")
	assertEqual(left.Tail, 0x123456789abcdef0)
	assertEqual(right.Marker, 29)
	assertEqual(right.Label, "right")
	assertEqual(right.Tail, 0xfedcba9876543210)
	assertEqual(len(left.Tokens), 2)
	assertEqual(len(right.Tokens), 1)
	assertEqual(left.Tokens[0].Get(), seed)
	assertEqual(left.Tokens[1].Get(), seed+1)
	assertEqual(right.Tokens[0].Get(), seed+5)
	assertEqual(api.Inspect([]api.BorrowedToken{
		{Marker: 3, Value: left.Tokens[0]},
		{Marker: 7, Value: right.Tokens[0]},
	}), 3*seed+7*(seed+5))
	assertEqual(left.Tokens[0].Get(), seed)
	for _, token := range append(left.Tokens, right.Tokens...) {
		token.Drop()
		token.Drop()
	}
}

func Run() {
	start := api.DropCount()
	check(api.Echo(batch(100)), 100)
	assertEqual(api.DropCount(), start+3)
	check(mirror.Echo([]api.Batch{batch(150)})[0], 150)
	assertEqual(api.DropCount(), start+6)

	control := api.Echo(api.Batch{
		Prefix:  73,
		Outcome: Err[api.Entry, uint32](901),
		Suffix:  37,
	})
	assertEqual(control.Prefix, 73)
	assertEqual(control.Suffix, 37)
	assertEqual(control.Optional.IsSome(), false)
	assertEqual(control.Outcome.Err(), 901)
	assertEqual(api.Echo(api.Batch{Outcome: Ok[api.Entry, uint32](api.MakeEntryEmpty())}).Outcome.Ok().Tag(), api.EntryEmpty)
	assertEqual(api.Echo(api.Batch{Outcome: Ok[api.Entry, uint32](api.MakeEntryCode(417))}).Outcome.Ok().Code(), 417)

	tx, rx := api.MakeStreamBatch()
	stream := api.ShortReads(rx)
	tx.WriteAll([]api.Batch{batch(200), batch(300), batch(400)})
	tx.Drop()
	for _, seed := range []uint32{200, 300, 400} {
		buffer := make([]api.Batch, 1)
		assertEqual(stream.Read(buffer), 1)
		check(buffer[0], seed)
	}
	stream.Drop()
	assertEqual(api.DropCount(), start+15)

	tx1, rx1 := api.MakeFutureBatch()
	tx2, rx2 := api.MakeFutureBatch()
	first, second := api.DroppedReader(rx1, rx2)
	value := batch(700)
	assertEqual(tx1.Write(value), false)
	assertEqual(tx2.Write(value), true)
	first.Drop()
	check(second.Read(), 700)
	second.Drop()
	tx1.Drop()
	tx2.Drop()
	assertEqual(api.DropCount(), start+18)
}

func assertEqual[T comparable](actual, expected T) {
	if actual != expected {
		panic(fmt.Sprintf("got %v, expected %v", actual, expected))
	}
}
