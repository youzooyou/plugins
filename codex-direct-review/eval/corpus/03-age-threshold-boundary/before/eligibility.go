package eligibility

// IsEligible reports whether a customer meets the minimum age requirement
// for renting a vehicle. Per the rental agreement, a customer becomes
// eligible on their 21st birthday -- i.e. turning 21 today already
// qualifies them to rent.
func IsEligible(age int) bool {
	return age > 21
}
