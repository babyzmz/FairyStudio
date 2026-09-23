// 递归
func factorial(_ n: Int) -> Int {
    n <= 1 ? 1 : n * factorial(n - 1)
}
func fib(_ n: Int) -> Int {
    if n < 2 { return n }
    return fib(n - 1) + fib(n - 2)
}
func gcd(_ a: Int, _ b: Int) -> Int {
    b == 0 ? a : gcd(b, a % b)
}
print(factorial(10), factorial(20))
print((0...15).map { fib($0) })
print(gcd(48, 18), gcd(17, 5))
func power(_ base: Int, _ exp: Int) -> Int {
    if exp == 0 { return 1 }
    let half = power(base, exp / 2)
    return exp % 2 == 0 ? half * half : half * half * base
}
print(power(2, 10), power(3, 5))
func sumDigits(_ n: Int) -> Int {
    n < 10 ? n : n % 10 + sumDigits(n / 10)
}
print(sumDigits(987654321))
