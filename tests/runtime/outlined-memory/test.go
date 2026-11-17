//@ args = '--outline-memory'

package export_test_outlined_memory_api

import (
	"runtime"
	. "wit_component/test_outlined_memory_api"

	. "go.bytecodealliance.org/pkg/wit/types"
)

var drops uint32

type Token struct {
	pinner runtime.Pinner
	handle int32
	value  uint32
}

func MakeToken(value uint32) *Token {
	return &Token{value: value}
}

func (self *Token) Get() uint32 { return self.value }
func (self *Token) OnDrop()     { drops++ }
func DropCount() uint32         { return drops }

func Echo(value Batch) Batch { return value }

func LargeEcho(value LevelFive) LevelFive { return value }

func Inspect(values []BorrowedToken) uint32 {
	var result uint32
	for _, value := range values {
		result += value.Marker * value.Value.Get()
	}
	return result
}

func ShortReads(values *StreamReader[Batch]) *StreamReader[Batch] {
	tx, rx := MakeStreamBatch()
	go func() {
		defer values.Drop()
		defer tx.Drop()
		var packets []Batch
		for !values.WriterDropped() {
			buffer := make([]Batch, 1)
			if values.Read(buffer) == 1 {
				packets = append(packets, buffer[0])
			}
		}
		tx.WriteAll(packets)
	}()
	return rx
}

func DroppedReader(first, second *FutureReader[Batch]) (*FutureReader[Batch], *FutureReader[Batch]) {
	tx1, rx1 := MakeFutureBatch()
	tx2, rx2 := MakeFutureBatch()
	go func() {
		defer first.Drop()
		defer second.Drop()
		defer tx1.Drop()
		defer tx2.Drop()
		first.Drop()
		value := second.Read()
		if tx1.Write(value) || !tx2.Write(value) {
			panic("future write did not preserve unconsumed handles")
		}
	}()
	return rx1, rx2
}
