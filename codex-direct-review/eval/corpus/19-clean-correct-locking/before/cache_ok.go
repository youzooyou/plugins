package cache

import "sync"

type Cache struct {
	mu   sync.Mutex
	data map[string]int
}

func NewCache() *Cache {
	return &Cache{data: make(map[string]int)}
}

// IncrementAll increments the counter for each key concurrently, safely.
func (c *Cache) IncrementAll(keys []string) {
	var wg sync.WaitGroup
	for _, k := range keys {
		wg.Add(1)
		go func(key string) {
			defer wg.Done()
			c.mu.Lock()
			c.data[key]++
			c.mu.Unlock()
		}(k)
	}
	wg.Wait()
}
