#include <numeric>
#include <string>
#include <vector>

int main()
{
    std::vector<int> values{1, 2, 3, 4};
    std::string name = "loongarch";

    if (std::accumulate(values.begin(), values.end(), 0) != 10)
        return 1;
    if (name.size() != 9)
        return 2;
    return 0;
}
