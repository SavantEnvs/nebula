/* Parses a query with nebula's own GQLParser and evaluates the expressions of its YIELD/RETURN
 * sentences (constant folding and function calls included), as graphd does for `YIELD round(5)`. */

#include "common/base/Base.h"
#include "common/context/ExpressionContext.h"
#include "common/expression/Expression.h"
#include "graph/context/QueryContext.h"
#include "parser/GQLParser.h"
#include "parser/SequentialSentences.h"
#include "parser/TraverseSentences.h"

namespace {

// No storage behind it: every lookup is NULL. Only the inner variables of list comprehensions,
// predicates and reduce are kept, per input.
class NullContext final : public nebula::ExpressionContext {
 public:
  using Value = nebula::Value;

  const Value& getVar(const std::string& var) const override {
    return lookup(var);
  }
  void setInnerVar(const std::string& var, Value val) override {
    inner_[var] = std::move(val);
  }
  const Value& getInnerVar(const std::string& var) const override {
    return lookup(var);
  }
  const Value& getVersionedVar(const std::string&, int64_t) const override {
    return Value::kNullValue;
  }
  const Value& getVarProp(const std::string&, const std::string&) const override {
    return Value::kNullValue;
  }
  nebula::StatusOr<std::size_t> getVarPropIndex(const std::string&,
                                                const std::string&) const override {
    return nebula::Status::Error("no such property");
  }
  Value getEdgeProp(const std::string&, const std::string&) const override {
    return Value::kNullValue;
  }
  Value getTagProp(const std::string&, const std::string&) const override {
    return Value::kNullValue;
  }
  Value getSrcProp(const std::string&, const std::string&) const override {
    return Value::kNullValue;
  }
  const Value& getDstProp(const std::string&, const std::string&) const override {
    return Value::kNullValue;
  }
  const Value& getInputProp(const std::string&) const override {
    return Value::kNullValue;
  }
  nebula::StatusOr<std::size_t> getInputPropIndex(const std::string&) const override {
    return nebula::Status::Error("no such property");
  }
  Value getVertex(const std::string& = "") const override {
    return Value::kNullValue;
  }
  Value getEdge() const override {
    return Value::kNullValue;
  }
  const Value& getColumn(int32_t) const override {
    return Value::kNullValue;
  }
  void setVar(const std::string& var, Value val) override {
    inner_[var] = std::move(val);
  }

 private:
  const Value& lookup(const std::string& var) const {
    auto it = inner_.find(var);
    return it == inner_.end() ? Value::kNullValue : it->second;
  }

  std::unordered_map<std::string, Value> inner_;
};

}  // namespace

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
  nebula::graph::QueryContext qctx;
  nebula::GQLParser parser(&qctx);
  const char* ptr = reinterpret_cast<const char*>(data);
  auto result = parser.parse(std::string(ptr, size));
  if (!result.ok()) {
    return -1;
  }
  auto sentence = std::move(result).value();
  if (sentence->kind() != nebula::Sentence::Kind::kSequential) {
    return 0;
  }
  NullContext ctx;
  for (auto* s : static_cast<nebula::SequentialSentences*>(sentence.get())->sentences()) {
    if (s->kind() != nebula::Sentence::Kind::kYield) {
      continue;
    }
    for (auto* column : static_cast<nebula::YieldSentence*>(s)->columns()) {
      column->expr()->eval(ctx);
    }
  }
  return 0;
}
