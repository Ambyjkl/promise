require "spec"
require "../src/promise"

Log = [] of Symbol | Nil
Wait = Channel(Bool).new

describe Promise do
  Spec.before_each do
    Log.clear
  end

  describe "resolve" do
    it "should call the callback in the next turn" do
      p = Promise.new(Symbol)
      p.then { |value| Log << value; Wait.send(true) }
      p.resolve(:foo)

      # wait for resolution
      Wait.receive
      Log.should eq([:foo])
    end

    it "can modify the result of a promise before returning" do
      p = Promise.new(Symbol)
      change = p.then { |value| "value type change #{value}" }
      p.resolve(:foo)

      # wait for resolution
      change.value.should eq("value type change foo")
    end

    it "should be able to resolve the callback after it has already been resolved" do
      p = Promise.new(Symbol)
      p.then do |value|
        Log << value
        p.then do |value|
          Log << value
          Wait.send(true)
        end
      end
      p.resolve(:foo)
      Wait.receive

      Log.should eq([:foo, :foo])
    end

    it "should fulfill success callbacks in the registration order" do
      p = Promise.new(Symbol)
      p.then { |value| Log << :first }
      p.then { |value| Log << :second }
      p.resolve(:foo)
      p.value

      Log.should eq([:first, :second])
    end

    it "should do nothing if a promise was previously resolved" do
      p = Promise.new(Symbol)
      p.then { |value| Log << value.not_nil! }
      p.resolve(:first)
      p.resolve(:second)
      p.then { |value| Log << value; Wait.send(true) }
      p.resolve(:second)

      Wait.receive
      Log.should eq([:first, :first])
    end

    it "should allow deferred resolution with a new promise" do
      p1 = Promise.new(Symbol)
      p1.then { |value| Log << value }
      p2 = Promise.new(Symbol)
      p1.resolve(p2)
      p2.resolve(:foo)

      p1.value.should eq(:foo)
      Log.should eq([:foo])
    end

    it "should not break if a callbacks registers another callback" do
      p = Promise.new(Symbol)
      p.then do |value|
        Log << :outer
        p.then do |value|
          Log << :inner
          Wait.send(true)
        end
      end
      p.resolve(:foo)

      Wait.receive
      Log.should eq([:outer, :inner])
    end
  end

  describe "reject" do
    it "should reject the promise and execute all error callbacks" do
      p = Promise.new(Symbol)
      p.catch { |result| Log << :first; :error1 }
      p.catch { |result| Log << :second; Wait.send(true); :error2 }
      p.reject("failed")

      Wait.receive
      Log.should eq([:first, :second])
    end

    it "should do nothing if a promise was previously rejected" do
      p = Promise.new(Symbol)
      p.then { |result| Log << :then; Wait.send(true) }
      p.catch { |result| Log << :catch; Wait.send(true); :error1 }
      p.reject("failed")
      p.resolve(:foo)

      Wait.receive
      Log.should eq([:catch])
    end
  end

  describe "then" do
    it "should notify all callbacks with the original value" do
      p = Promise.new(Symbol)
      p.catch { |error| Log << :error; :error1 }
      p.then { |result| Log << result; :alt }
      p.then { |result| Log << result; "str" }
      p.then { |result| Log << result; Promise.reject(Symbol, "error") }
      p.then { |result| Log << result; Wait.send(true) }
      p.resolve(:foo)
      Wait.receive
      Log.should eq([:foo, :foo, :foo, :foo])
    end

    it "should reject all callbacks with the original reason" do
      p = Promise.new(Symbol)
      p.then { |result| Log << :bad }
      p.catch { |error| Log << :good; :error1 }
      p.catch { |error| Log << :good; :error2 }
      p.catch { |error| Log << :good; Promise.reject(Symbol, "error") }
      p.catch { |error| Log << :good; Wait.send(true); :error4 }
      p.reject("some error")
      Wait.receive
      Log.should eq([:good, :good, :good, :good])
    end

    it "should propagate resolution and rejection between dependent promises" do
      p = Promise.new(Symbol)
      p.then { |result| Log << result; :alt }
        .then { |result| Log << result; raise "error"; :type }
        .catch do |error|
          Log << :error1 if error.message == "error"
          Promise.reject(Symbol, "error2")
        end
        .catch do |error|
          Log << :error2 if error.message == "error2"
          :resolved
        end
        .then do |result|
          Log << :was_number if result == :resolved
          Wait.send(true)
        end
      p.resolve(:foo)
      Wait.receive
      Log.should eq([:foo, :alt, :error1, :error2, :was_number])
    end

    it "should propagate success through rejection only promises" do
      p = Promise.new(Symbol)
      p.catch { |error| Log << :error1; :error1 }
        .catch { |error| Log << :error2; :error2 }
        .then do |result|
          Log << result
          Wait.send(true)
        end
      p.resolve(:foo)
      Wait.receive
      Log.should eq([:foo])
    end

    it "should propagate rejections through resolution only promises" do
      p = Promise.new(Symbol)
      p.then { |result| Log << result; :alt }
        .then { |result| Log << result }
        .catch do |error|
          Log << :error1 if error.message == "errors all the way down"
          Wait.send(true)
        end
      p.reject("errors all the way down")
      Wait.receive
      Log.should eq([:error1])
    end

    describe "finally" do
      describe "when the promise is fulfilled" do
        it "should call the callback" do
          p = Promise.new(Symbol)
          p.finally { |value| Log << :finally }
          p.resolve(:foo)
          p.value

          Log.should eq([:finally])
        end

        it "should fulfill with the original value" do
          p = Promise.new(Symbol)
          other = p.finally { |value| Log << :finally; :test }.then { |result| Log << result }
          p.resolve(:foo)
          other.value

          Log.should eq([:finally, :test])
        end

        it "should reject with this new exception" do
          p = Promise.new(Symbol)
          fin = p.finally { |value| Log << :finally; raise "error" }
          fin.then { |result| Log << :no_error; Wait.send(true) }
          fin.catch { |error| Log << :error; Wait.send(true) }
          p.resolve(:foo)

          Wait.receive
          Log.should eq([:finally, :error])
        end

        it "should fulfill with the original reason after that promise resolves" do
          p1 = Promise.new(Symbol)
          p2 = Promise.new(Symbol)
          p1.finally { |value|
            Log << :finally; p2
          }.then { |result|
            Log << result
            Wait.send(true)
          }
          
          p1.resolve(:fin)

          delay(0) do
            delay(0) do
              delay(0) do
                Log << :resolving
                p2.resolve(:foo)
              end
            end
          end

          Wait.receive
          Log.should eq([:finally, :resolving, :foo])
        end

        it "should reject with the new reason when it is rejected" do
          p1 = Promise.new(Symbol)
          p2 = Promise.new(Symbol)
          p1.finally { |value|
            Log << :finally; p2
          }.catch { |error|
            Log << :error
            Wait.send(true)
          }
          
          p1.resolve(:fin)

          delay(0) do
            delay(0) do
              delay(0) do
                Log << :rejecting
                p2.reject("error")
              end
            end
          end

          Wait.receive
          Log.should eq([:finally, :rejecting, :error])
        end
      end
    end
  end
end
